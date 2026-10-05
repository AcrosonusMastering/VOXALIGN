-- @description VoxAlign v15.2.0 — Robust Active-Audio Bounds, Chunked Audio I/O, FastDTW Pyramid & Breath Protection
-- @version 15.2.0
-- @author Acrosonus Mastering
-- @about Hybrid temporal alignment for REAPER with 4-band spectral analysis, FastDTW Pyramid (1/16->1/4->1/1), active-audio islands, virtual internal-silence compaction, bounded audio I/O, transactional stretch-marker replacement, Itakura bounds, and Breath Protection.
 
for key in pairs(reaper) do _G[key] = reaper[key] end 
 
local app_vrs = tonumber(GetAppVersion():match('[%d%.]+')) or 0 
if app_vrs < 7.0 then return MB('REAPER 7.0+ required.', 'Error', 0) end 
if not reaper.ImGui_GetBuiltinPath then return MB('ReaImGui required.', 'Error', 0) end 
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua' 
local ImGui = require 'imgui' '0.9.3' 
local ctx = ImGui.CreateContext('VoxAlign v15.2.0')
 
-------------------------------------------------------------------- 
-- PARAMÈTRES 
-------------------------------------------------------------------- 
local EXT = { 
  -- Étape 1: Macro 
  enable_step1        = true,      
  max_shift_sec       = 0.5, 
  method              = "AUTO", 
  rigid_align         = true,      
   
  -- Étape 1.5: Segmentation & Respirations 
  use_segmentation    = true, 
  zcr_threshold       = 0.15, 
  transient_threshold = 0.15, 
  blob_gap_ms         = 100, 
  min_blob_ms         = 40, 
  blob_thresh_min_db  = -60,  
  blob_thresh_max_db  = -30,  
  
  -- Module C: Breath Protection
  enable_breath_protect = true,
  breath_zcr_min      = 0.22,
  breath_air_min      = 0.20,
  breath_sub_max      = 0.10,
   
  -- Analyse 
  fp_sr               = 2000, 
  fp_smooth           = 0.9, 
  fp_percentile       = 0.75, 
  wf_sr               = 8000, 
  wf_refine_radius_sec= 0.025,  
  window_ms           = 15, 
  hop_ms              = 5, 
  smooth_ms           = 20, 
   
  -- Étape 2: DTW & Paramètres Avancés 
  enable_step2        = true,      
  use_fastdtw_pyramid = true,
  gate_db             = -45,       
  dtw_band_ms         = 200, 
  marker_min_gap_ms   = 100, 
  max_stretch_ratio   = 1.8, 
  align_strength      = 0.85, 
  onset_thr_db        = 4.5,
  split_freq_low      = 300,   
  split_freq_mid      = 2500,  
  split_freq_high     = 6000,  
  dtw_feature_weight  = 0.60, 
  dtw_delta_weight    = 0.15,
  dtw_zcr_weight      = 0.10,  
  dtw_slope_penalty   = 0.08, 
  anchor_min_conf     = 0.25, 
  drift_tolerance_sec = 0.150,
  _preset_idx         = 0,
   
  -- Micro-align & Anti-clics 
  use_zero_crossing   = true,      
  zx_window_ms        = 5,         
  use_pre_emphasis    = true,      
  marker_offset_ms    = -2.0, 
  use_micro_align     = true, 
  micro_window_ms     = 150,       
  micro_sr             = 8000,     
  micro_corr_threshold = 0.30,      
  debug_mode          = true,      

  -- V15 Robustness / Active Audio Bounds
  auto_trim_analysis  = true,
  analysis_scan_rate  = 100,       -- peak scans per source second
  analysis_threshold_db = -60,     -- activity threshold for leading/trailing silence
  analysis_release_db = -66,       -- lower release threshold for hysteresis
  analysis_padding_ms = 250,       -- safety padding kept around detected audio
  min_analysis_overlap_sec = 0.100,
  audio_read_chunk_sec = 8.0,      -- hard cap per AudioAccessor read
  max_source_read_sec = 0.0,       -- 0 = no artificial cap; reads remain chunked
  compact_internal_silence = true, -- virtual compaction of long internal silences
} 

local _smooth_weights_cache = {}  

local _settings_dirty = false
local function MarkSettingsDirty()
  _settings_dirty = true
  _smooth_weights_cache = {}
end

local EXTSTATE_SECTION = "Acrosonus_AlignTakes_v15_1"
local LEGACY_EXTSTATE_SECTION = "Acrosonus_AlignTakes_v15"
local LEGACY_EXTSTATE_SECTION_V14 = "Acrosonus_AlignTakes_v14"

local function SerializeEXT()
  local parts = {}
  for k, v in pairs(EXT) do
    if type(v) == "number" then
      parts[#parts+1] = k .. "=N:" .. tostring(v)
    elseif type(v) == "boolean" then
      parts[#parts+1] = k .. "=B:" .. (v and "1" or "0")
    elseif type(v) == "string" then
      parts[#parts+1] = k .. "=S:" .. string.format("%q", v)
    end
  end
  return table.concat(parts, ";")
end

local function DeserializeEXT(str)
  if not str or str == "" then return end
  for entry in string.gmatch(str, "([^;]+)") do
    local key, typ, val = entry:match("^(.-)=([NBS]):(.*)$")
    if key then
      if typ == "N" then EXT[key] = tonumber(val)
      elseif typ == "B" then EXT[key] = (val == "1")
      elseif typ == "S" then
        local decode_fn = load("return " .. val, "ext_string", "t", {})
        local ok, decoded = false, nil
        if decode_fn then ok, decoded = pcall(decode_fn) end
        EXT[key] = (ok and type(decoded) == "string") and decoded or val
      end
    end
  end
end

local function SaveSettings()
  SetExtState(EXTSTATE_SECTION, "params", SerializeEXT(), true)
end

local function ClampParam(v, lo, hi, default)
  if type(v) ~= "number" or v ~= v then return default end
  return math.max(lo, math.min(hi, v))
end

local EXT_DEFAULTS = {
  hop_ms              = { 1,    50,   5     },
  window_ms           = { 5,   100,  15     },
  fp_smooth           = { 0.0,  0.99, 0.9   },
  fp_percentile       = { 0.1,  0.99, 0.75  },
  max_shift_sec       = { 0.05, 5.0,  0.5   },
  dtw_band_ms         = { 10,  2000, 200    },
  max_stretch_ratio   = { 1.0,  5.0,  1.8   },
  align_strength      = { 0.0,  1.0,  0.85  },
  dtw_feature_weight  = { 0.0,  1.0,  0.60  },
  dtw_delta_weight    = { 0.0,  1.0,  0.15  },
  dtw_zcr_weight      = { 0.0,  1.0,  0.10  },
  dtw_slope_penalty   = { 0.0,  0.5,  0.08  },
  anchor_min_conf     = { 0.0,  1.0,  0.25  },
  drift_tolerance_sec = { 0.01, 2.0,  0.150 },
  gate_db             = { -80, -10,  -45    },
  fp_sr               = { 500, 8000, 2000   },
  wf_sr               = { 1000,44100,8000   },
  zx_window_ms        = { 1,   50,    5     },
  micro_window_ms     = { 20,  500,  150    },
  onset_thr_db        = { 0.5, 20.0,  4.5   },
  blob_gap_ms         = { 10,  500,  100    },
  min_blob_ms         = { 10,  500,   40    },
  blob_thresh_min_db  = { -90, -20,  -60    },
  blob_thresh_max_db  = { -50, -10,  -30    },
  zcr_threshold       = { 0.01, 1.0,  0.15  },
  transient_threshold = { 0.01, 1.0,  0.15  },
  wf_refine_radius_sec= { 0.005,1.0,  0.025 },
  split_freq_low      = { 100, 1000, 300    },
  split_freq_mid      = { 1000,4000, 2500   },
  split_freq_high     = { 4000,12000,6000   },
  smooth_ms           = { 1,  200,   20     },
  marker_offset_ms    = { -20.0, 20.0, -2.0 },
  marker_min_gap_ms   = { 20,  500,  100    },
  micro_sr            = { 2000, 22050, 8000 },
  micro_corr_threshold= { 0.05, 0.90, 0.30  },
  breath_zcr_min      = { 0.05, 0.80, 0.22  },
  breath_air_min      = { 0.05, 0.90, 0.20  },
  breath_sub_max      = { 0.01, 0.50, 0.10  },
  analysis_scan_rate  = { 20,   500,   100   },
  analysis_threshold_db = { -100, -20, -60   },
  analysis_release_db = { -110, -20, -66     },
  analysis_padding_ms = { 0,    2000, 250    },
  min_analysis_overlap_sec = { 0.020, 5.0, 0.100 },
  audio_read_chunk_sec = { 0.25, 60.0, 8.0   },
  max_source_read_sec = { 0.0,  3600.0, 0.0  },
  analysis_merge_gap_ms = { 20,  2000, 180 },
  analysis_min_active_ms = { 10,  2000, 35 },
  max_audio_buffer_mb = { 32,  1024, 256 },
}

local function ValidateEXT()
  for key, bounds in pairs(EXT_DEFAULTS) do
    EXT[key] = ClampParam(EXT[key], bounds[1], bounds[2], bounds[3])
  end
  local bool_fields = { "enable_step1", "enable_step2", "rigid_align",
    "use_segmentation", "use_zero_crossing", "use_pre_emphasis", "use_micro_align", 
    "debug_mode", "enable_breath_protect", "use_fastdtw_pyramid", "auto_trim_analysis", "compact_internal_silence" }
  for _, k in ipairs(bool_fields) do
    if type(EXT[k]) ~= "boolean" then EXT[k] = (EXT[k] ~= nil and EXT[k] ~= 0 and EXT[k] ~= false) end
  end
  if type(EXT.compact_internal_silence) ~= "boolean" then EXT.compact_internal_silence = true end
  local valid_methods = { AUTO=true, FINGERPRINT=true, WAVEFORM=true, ENVELOPE=true }
  if not valid_methods[EXT.method] then EXT.method = "AUTO" end
  if type(EXT._preset_idx) ~= "number" then EXT._preset_idx = 0 end
end

local function LoadSettings()
  local str = GetExtState(EXTSTATE_SECTION, "params")
  if not str or str == "" then
    -- V15 keeps the V14 user parameters when upgrading, then saves them
    -- under the new namespace after the first parameter change.
    str = GetExtState(LEGACY_EXTSTATE_SECTION, "params")
    if not str or str == "" then
      str = GetExtState(LEGACY_EXTSTATE_SECTION_V14, "params")
    end
  end
  DeserializeEXT(str)
  ValidateEXT()
end

LoadSettings()
 
-------------------------------------------------------------------- 
-- ÉTAT GLOBAL & UTILS MATHÉMATIQUES 
-------------------------------------------------------------------- 
local DATA = { ref = nil, dubs = {}, has_aligned = false, log = "" } 
local STATE = { 
  mode = "idle", 
  progress = 0, 
  progress_text = "", 
  dub_index = 0, 
} 
 
local LOG_MAX_LINES = 400
local _log_lines = {}
local _log_head  = 1
local _log_count = 0
local _log_truncated = false
local _log_dirty = false

local function log(s)
  if _log_count >= LOG_MAX_LINES then
    _log_truncated = true
  else
    _log_count = _log_count + 1
  end
  _log_lines[_log_head] = tostring(s)
  _log_head = _log_head % LOG_MAX_LINES + 1
  _log_dirty = true
end

local function FlushLog()
  if not _log_dirty then return end
  local n = _log_count
  if n == 0 then DATA.log = ""; _log_dirty = false; return end
  local parts = {}
  local base = 0
  if _log_truncated then
    parts[1] = "...(historique tronqué)..."
    base = 1
  end
  if n < LOG_MAX_LINES then
    for i = 1, n do parts[base + i] = _log_lines[i] or "" end
  else
    for i = 0, LOG_MAX_LINES - 1 do
      local slot = (_log_head - 1 + i) % LOG_MAX_LINES + 1
      parts[base + i + 1] = _log_lines[slot] or ""
    end
  end
  DATA.log = table.concat(parts, "\n")
  _log_dirty = false
end

local function ResetLog()
  _log_lines = {}
  _log_head  = 1
  _log_count = 0
  _log_truncated = false
  _log_dirty = false
  DATA.log   = ""
end

local function val2db(v) return (v > 1e-9) and (20 * math.log(v, 10)) or -200 end 
 
local function ClearStretchMarkers(take) 
  if take then DeleteTakeStretchMarkers(take, 0, GetTakeNumStretchMarkers(take)) end 
end 
 
local function ParabolicPeak(y1, y2, y3) 
  local denom = y1 - 2 * y2 + y3 
  if math.abs(denom) < 1e-12 then return 0 end 
  return 0.5 * (y1 - y3) / denom 
end 

--------------------------------------------------------------------
-- FFT COOLEY-TUKEY (Radix-2, DIT, Lua pur)
--------------------------------------------------------------------
local function FFT(re, im, invert)
  local n = #re
  local j = 0
  for i = 1, n - 1 do
    local bit = n >> 1
    while j >= bit do j = j - bit; bit = bit >> 1 end
    j = j + bit
    if i < j then
      re[i+1], re[j+1] = re[j+1], re[i+1]
      im[i+1], im[j+1] = im[j+1], im[i+1]
    end
  end
  local len = 2
  while len <= n do
    local ang = 2 * math.pi / len * (invert and 1 or -1)
    local wre, wim = math.cos(ang), math.sin(ang)
    for i = 0, n - 1, len do
      local cur_wre, cur_wim = 1.0, 0.0
      for k = 0, len/2 - 1 do
        local u_re = re[i + k + 1]
        local u_im = im[i + k + 1]
        local v_re = re[i + k + len/2 + 1] * cur_wre - im[i + k + len/2 + 1] * cur_wim
        local v_im = re[i + k + len/2 + 1] * cur_wim + im[i + k + len/2 + 1] * cur_wre
        re[i + k + 1]         = u_re + v_re
        im[i + k + 1]         = u_im + v_im
        re[i + k + len/2 + 1] = u_re - v_re
        im[i + k + len/2 + 1] = u_im - v_im
        local new_wre = cur_wre * wre - cur_wim * wim
        cur_wim = cur_wre * wim + cur_wim * wre
        cur_wre = new_wre
      end
    end
    len = len * 2
  end
  if invert then
    for i = 1, n do re[i] = re[i] / n; im[i] = im[i] / n end
  end
end

local function NextPow2(n)
  n = math.max(1, math.floor(n or 1))
  local p = 1
  while p < n do p = p * 2 end
  return p
end

local function FindCorrelationOffset_FFT(ref_arr, dub_arr, sample_rate, max_shift_sec, center_lag_sec, radius_sec)
  local N = #ref_arr
  local M = #dub_arr
  if N < 4 or M < 4 then return 0, 0 end

  local fft_size = NextPow2(N + M - 1)

  local lag_min, lag_max
  if radius_sec then
    local center_lag = math.floor(-(center_lag_sec or 0) * sample_rate + 0.5)
    local radius_lag = math.max(1, math.floor(radius_sec * sample_rate))
    local full_max   = math.floor(max_shift_sec * sample_rate)
    lag_min = math.max(-full_max, center_lag - radius_lag)
    lag_max = math.min(full_max,  center_lag + radius_lag)
  else
    local full_max = math.floor(max_shift_sec * sample_rate)
    lag_min, lag_max = -full_max, full_max
  end

  local re_r, im_r = {}, {}
  local re_d, im_d = {}, {}
  for i = 1, fft_size do
    re_r[i] = ref_arr[i] or 0; im_r[i] = 0
    re_d[i] = dub_arr[i] or 0; im_d[i] = 0
  end

  FFT(re_r, im_r, false)
  FFT(re_d, im_d, false)

  local re_c, im_c = {}, {}
  for i = 1, fft_size do
    re_c[i] = re_r[i] * re_d[i] + im_r[i] * im_d[i]
    im_c[i] = im_r[i] * re_d[i] - re_r[i] * im_d[i]
  end

  FFT(re_c, im_c, true)

  local e_ref, e_dub = 0, 0
  for i = 1, N do e_ref = e_ref + ref_arr[i] * ref_arr[i] end
  for i = 1, M do e_dub = e_dub + dub_arr[i] * dub_arr[i] end
  local norm_global = math.sqrt(e_ref * e_dub)
  if norm_global < 1e-9 then return 0, 0 end

  local best_ncc = -math.huge
  local best_lag = 0
  local corrs = {}

  for lag = lag_min, lag_max do
    local idx = lag >= 0 and (lag + 1) or (fft_size + lag + 1)
    local c = (re_c[idx] or 0) / norm_global
    corrs[lag] = c
    if c > best_ncc then best_ncc = c; best_lag = lag end
  end

  local y1 = corrs[best_lag - 1] or best_ncc
  local y2 = corrs[best_lag]     or best_ncc
  local y3 = corrs[best_lag + 1] or best_ncc
  local frac = ParabolicPeak(y1, y2, y3)
  frac = math.max(-0.5, math.min(0.5, frac))

  return -(best_lag + frac) / sample_rate, best_ncc
end

local function CumSumSquares(arr)
  local cum = {0}
  for i = 1, #arr do cum[i+1] = cum[i] + arr[i] * arr[i] end
  return cum
end

local function LocalEnergy(cumsum, a, b)
  a = math.max(1, a)
  b = math.min(#cumsum - 1, b)
  if b < a then return 0 end
  return cumsum[b+1] - cumsum[a]
end

local function FindCorrelationOffset_WLNCC(ref_arr, dub_arr, sample_rate, max_shift_sec, center_lag_sec, radius_sec)
  local N = #ref_arr
  local M = #dub_arr
  if N < 4 or M < 4 then return 0, 0 end

  local fft_size = NextPow2(N + M - 1)

  local lag_min, lag_max
  if radius_sec then
    local center_lag = math.floor(-(center_lag_sec or 0) * sample_rate + 0.5)
    local radius_lag = math.max(1, math.floor(radius_sec * sample_rate))
    local full_max   = math.floor(max_shift_sec * sample_rate)
    lag_min = math.max(-full_max, center_lag - radius_lag)
    lag_max = math.min(full_max,  center_lag + radius_lag)
  else
    local full_max = math.floor(max_shift_sec * sample_rate)
    lag_min, lag_max = -full_max, full_max
  end

  local re_r, im_r = {}, {}
  local re_d, im_d = {}, {}
  for i = 1, fft_size do
    re_r[i] = ref_arr[i] or 0; im_r[i] = 0
    re_d[i] = dub_arr[i] or 0; im_d[i] = 0
  end

  FFT(re_r, im_r, false)
  FFT(re_d, im_d, false)

  local re_c, im_c = {}, {}
  for i = 1, fft_size do
    re_c[i] = re_r[i] * re_d[i] + im_r[i] * im_d[i]
    im_c[i] = im_r[i] * re_d[i] - re_r[i] * im_d[i]
  end

  FFT(re_c, im_c, true)

  local cum_ref = CumSumSquares(ref_arr)
  local cum_dub = CumSumSquares(dub_arr)

  local best_ncc = -math.huge
  local best_lag = 0
  local corrs = {}

  for lag = lag_min, lag_max do
    local idx = lag >= 0 and (lag + 1) or (fft_size + lag + 1)
    local raw = re_c[idx] or 0

    local n_start = math.max(1, lag + 1)
    local n_end   = math.min(N, M + lag)
    if n_end > n_start then
      local e_ref_local = LocalEnergy(cum_ref, n_start, n_end)
      local e_dub_local = LocalEnergy(cum_dub, n_start - lag, n_end - lag)
      local norm_local = math.sqrt(e_ref_local * e_dub_local)
      if norm_local > 1e-9 then
        local c = raw / norm_local
        corrs[lag] = c
        if c > best_ncc then best_ncc = c; best_lag = lag end
      end
    end
  end

  if best_ncc == -math.huge then return 0, 0 end

  local y1 = corrs[best_lag - 1] or best_ncc
  local y2 = corrs[best_lag]     or best_ncc
  local y3 = corrs[best_lag + 1] or best_ncc
  local frac = ParabolicPeak(y1, y2, y3)
  frac = math.max(-0.5, math.min(0.5, frac))

  return -(best_lag + frac) / sample_rate, best_ncc
end

local function ApplyHann(arr)
  local n = #arr
  if n <= 1 then return arr end
  for i = 1, n do
    local w = 0.5 * (1 - math.cos(2 * math.pi * (i - 1) / (n - 1)))
    arr[i] = arr[i] * w
  end
  return arr
end
 
-------------------------------------------------------------------- 
-- ROBUSTESSE : LECTURE AUDIO VIA LA PISTE / TAKE (SUPPORT SPLIT ITEMS)
-- V15 does not destructively split media items. Analysis is restricted to
-- detected active-audio bounds while the original REAPER item remains intact.
-------------------------------------------------------------------- 
local function IsFiniteNumber(v)
  return type(v) == "number" and v == v and v < math.huge and v > -math.huge
end

local function GetTakeSourceBounds(take)
  if not take or not ValidatePtr2(0, take, "MediaItem_Take*") then return nil end
  local item = GetMediaItemTake_Item(take)
  if not item or not ValidatePtr2(0, item, "MediaItem*") then return nil end
  local item_len = GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  local take_offset = GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local play_rate = GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1.0
  if play_rate <= 0 then play_rate = 1.0 end
  local source = GetMediaItemTake_Source(take)
  local source_len = source and (GetMediaSourceLength(source) or 0) or 0
  local source_start = take_offset
  local source_end = take_offset + item_len * play_rate
  if source_len > 0 and IsFiniteNumber(source_len) then
    source_end = math.min(source_end, source_len)
  end
  if source_end <= source_start then return nil end
  return source_start, source_end, play_rate
end

local function GetMaxAudioBufferSamples(target_sr, num_channels)
  local mb = ClampParam(EXT.max_audio_buffer_mb, 32, 1024, 256)
  local bytes_budget = mb * 1024 * 1024
  -- Conservative estimate: Lua table entry + number value + allocator overhead.
  -- This is intentionally much higher than the 8-byte PCM sample itself.
  local estimated_bytes_per_value = 24
  local max_values = math.floor(bytes_budget / estimated_bytes_per_value)
  return math.max(10000, max_values)
end

local function ReadAudioAccessorChunked(accessor, target_sr, num_channels, start_time, total_samples, output)
  if not accessor or total_samples <= 0 then return 0, false end
  local chunk_sec = ClampParam(EXT.audio_read_chunk_sec, 0.25, 60.0, 8.0)
  local max_chunk_samples = math.max(1, math.floor(chunk_sec * target_sr + 0.5))
  local done_samples = 0
  local output_index = 1

  while done_samples < total_samples do
    local chunk_samples = math.min(max_chunk_samples, total_samples - done_samples)
    if EXT.max_source_read_sec and EXT.max_source_read_sec > 0 then
      local max_total = math.max(1, math.floor(EXT.max_source_read_sec * target_sr + 0.5))
      if done_samples >= max_total then break end
      chunk_samples = math.min(chunk_samples, max_total - done_samples)
    end
    if chunk_samples <= 0 then break end

    local buf = reaper.new_array(chunk_samples * num_channels)
    local ret = GetAudioAccessorSamples(
      accessor, target_sr, num_channels,
      start_time + done_samples / target_sr,
      chunk_samples, buf
    )
    if ret < 0 then
      return done_samples, false
    end

    local wanted = chunk_samples * num_channels
    if ret == 0 then
      for i = 1, wanted do
        output[output_index] = 0.0
        output_index = output_index + 1
      end
    else
      local t_read = buf.table()
      local got = math.min(#t_read, wanted)
      for i = 1, got do
        output[output_index] = t_read[i]
        output_index = output_index + 1
      end
      if got < wanted then
        for i = got + 1, wanted do
          output[output_index] = 0.0
          output_index = output_index + 1
        end
      end
    end
    done_samples = done_samples + chunk_samples
  end

  while output_index <= total_samples * num_channels do
    output[output_index] = 0.0
    output_index = output_index + 1
  end
  return done_samples, done_samples == total_samples
end

local function AppendAudioAccessorChunked(accessor, target_sr, num_channels, start_time, total_samples, output)
  if not accessor or total_samples <= 0 then return 0, false end
  local chunk_sec = ClampParam(EXT.audio_read_chunk_sec, 0.25, 60.0, 8.0)
  local max_chunk_samples = math.max(1, math.floor(chunk_sec * target_sr + 0.5))
  local done_samples = 0
  local output_index = #output + 1

  while done_samples < total_samples do
    local chunk_samples = math.min(max_chunk_samples, total_samples - done_samples)
    if EXT.max_source_read_sec and EXT.max_source_read_sec > 0 then
      local max_total = math.max(1, math.floor(EXT.max_source_read_sec * target_sr + 0.5))
      if done_samples >= max_total then break end
      chunk_samples = math.min(chunk_samples, max_total - done_samples)
    end
    if chunk_samples <= 0 then break end

    local buf = reaper.new_array(chunk_samples * num_channels)
    local ret = GetAudioAccessorSamples(
      accessor, target_sr, num_channels,
      start_time + done_samples / target_sr,
      chunk_samples, buf
    )
    if ret < 0 then
      return done_samples, false
    end

    local wanted = chunk_samples * num_channels
    if ret == 0 then
      for i = 1, wanted do
        output[output_index] = 0.0
        output_index = output_index + 1
      end
    else
      local t_read = buf.table()
      local got = math.min(#t_read, wanted)
      for i = 1, got do
        output[output_index] = t_read[i]
        output_index = output_index + 1
      end
      if got < wanted then
        for i = got + 1, wanted do
          output[output_index] = 0.0
          output_index = output_index + 1
        end
      end
    end
    done_samples = done_samples + chunk_samples
  end

  return done_samples, done_samples == total_samples
end

local function ReadTrackAudio(track, start_proj_time, end_proj_time, target_sr, num_channels, take)
  if not track or not ValidatePtr2(0, track, "MediaTrack*") then return nil end
  if not target_sr or target_sr <= 0 then return nil end
  if not num_channels or num_channels <= 0 then return nil end
  if not start_proj_time or not end_proj_time then return nil end
  if end_proj_time <= start_proj_time then return nil end
  if not IsFiniteNumber(start_proj_time) or not IsFiniteNumber(end_proj_time) then return nil end

  local total_duration = end_proj_time - start_proj_time
  if EXT.max_source_read_sec and EXT.max_source_read_sec > 0 and total_duration > EXT.max_source_read_sec then
    end_proj_time = start_proj_time + EXT.max_source_read_sec
    total_duration = end_proj_time - start_proj_time
  end

  local total_samples = math.ceil(total_duration * target_sr)
  if total_samples < 1 then return nil end

  local max_values = GetMaxAudioBufferSamples(target_sr, num_channels)
  local total_values = total_samples * num_channels
  if total_values > max_values then
    log(string.format(
      "  [ERROR] ReadTrackAudio: requested buffer %.2fs @ %d Hz (%d values) exceeds Lua safety budget (~%d values). Use compact analysis or lower the relevant analysis rate.",
      total_duration, target_sr, total_values, max_values
    ))
    return nil
  end

  local out_table = {}
  local read_success = false

  if take and ValidatePtr2(0, take, "MediaItem_Take*") then
    local item = GetMediaItemTake_Item(take)
    if item and ValidatePtr2(0, item, "MediaItem*") then
      local item_pos = GetMediaItemInfo_Value(item, 'D_POSITION') or 0
      local item_len = GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
      local item_end = item_pos + item_len
      local valid_start = math.max(start_proj_time, item_pos)
      local valid_end = math.min(end_proj_time, item_end)

      if valid_end > valid_start then
        local valid_samples = math.ceil((valid_end - valid_start) * target_sr)
        if valid_samples > 0 then
          local accessor = CreateTakeAudioAccessor(take)
          if accessor then
            local item_relative_start = valid_start - item_pos
            local read_count = AppendAudioAccessorChunked(
              accessor, target_sr, num_channels,
              item_relative_start, valid_samples, out_table
            )
            DestroyAudioAccessor(accessor)

            local expected_values = valid_samples * num_channels
            local start_sample_offset = math.floor((valid_start - start_proj_time) * target_sr + 0.5)
            local prefix_values = start_sample_offset * num_channels
            if prefix_values > 0 then
              local padded = {}
              for i = 1, prefix_values do padded[i] = 0.0 end
              for i = 1, #out_table do padded[prefix_values + i] = out_table[i] end
              out_table = padded
            end
            local wanted_total = total_samples * num_channels
            if #out_table < wanted_total then
              for i = #out_table + 1, wanted_total do out_table[i] = 0.0 end
            elseif #out_table > wanted_total then
              for i = wanted_total + 1, #out_table do out_table[i] = nil end
            end

            if read_count == valid_samples and #out_table == wanted_total then
              read_success = true
            end
          end
        end
      end
    end
  else
    local accessor = CreateTrackAudioAccessor(track)
    if accessor then
      local read_count = ReadAudioAccessorChunked(
        accessor, target_sr, num_channels,
        start_proj_time, total_samples, out_table
      )
      DestroyAudioAccessor(accessor)
      read_success = read_count > 0 and #out_table == total_samples * num_channels
    end
  end

  if not read_success then
    log(string.format(
      "  [WARN] ReadTrackAudio: no readable audio (proj_t=%.3f..%.3f, sr=%d, ch=%d)",
      start_proj_time, end_proj_time, target_sr, num_channels
    ))
    return nil
  end

  return out_table
end

local function ReadTrackAudioRanges(track, ranges, target_sr, num_channels, take, separator_sec)
  if not ranges or #ranges == 0 then return nil end
  local out = {}
  local sep_samples = math.max(0, math.floor((separator_sec or 0) * target_sr + 0.5))
  local total_duration = 0
  for i, r in ipairs(ranges) do
    if r and r.start and r.finish and r.finish > r.start then
      total_duration = total_duration + (r.finish - r.start)
      if i < #ranges then total_duration = total_duration + sep_samples / target_sr end
    end
  end
  local max_values = GetMaxAudioBufferSamples(target_sr, num_channels)
  local estimated_values = math.ceil(total_duration * target_sr) * num_channels
  if estimated_values > max_values then
    log(string.format(
      "  [ERROR] ReadTrackAudioRanges: compact analysis still requires %.1fs @ %d Hz (%d values), safety budget %.1fs. Alignment skipped for this buffer.",
      total_duration, target_sr, estimated_values, max_values / math.max(1, target_sr * num_channels)
    ))
    return nil
  end

  for i, r in ipairs(ranges) do
    if r and r.start and r.finish and r.finish > r.start then
      local block = ReadTrackAudio(track, r.start, r.finish, target_sr, num_channels, take)
      if not block then return nil end
      for j = 1, #block do out[#out + 1] = block[j] end
      if i < #ranges and sep_samples > 0 then
        for j = 1, sep_samples * num_channels do out[#out + 1] = 0.0 end
      end
    end
  end
  return (#out > 0) and out or nil
end

local function FindNearestZeroCrossing(take, target_src_t, search_window_ms) 
  local item = GetMediaItemTake_Item(take) 
  local item_pos = GetMediaItemInfo_Value(item, 'D_POSITION') 
  local item_len = GetMediaItemInfo_Value(item, 'D_LENGTH')
  local take_offset = GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  local play_rate   = GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  if not play_rate or play_rate <= 0 then return target_src_t end
  local track  = GetMediaItem_Track(item)
  local source = GetMediaItemTake_Source(take)
  if not source then return target_src_t end

  local sr = GetMediaSourceSampleRate(source)
  if sr <= 0 then sr = 44100 end

  local num_channels  = math.max(1, GetMediaSourceNumChannels(source))
  local target_proj_t = item_pos + (target_src_t - take_offset) / play_rate 
  local window_proj_sec = (search_window_ms / 1000) / play_rate 
  local start_proj_t = math.max(item_pos, target_proj_t - window_proj_sec) 
  local end_proj_t = math.min(item_pos + item_len, target_proj_t + window_proj_sec) 
   
  local t = ReadTrackAudio(track, start_proj_t, end_proj_t, sr, num_channels, take)
  if not t then return target_src_t end

  local num_samples = math.floor(#t / num_channels)
  if num_samples < 2 then return target_src_t end

  local peak = 0
  for i = 1, #t do peak = math.max(peak, math.abs(t[i] or 0)) end
  if peak < 1e-5 then return target_src_t end

  local target_sample_idx = (target_proj_t - start_proj_t) * play_rate * sr + 1
  local min_dist = math.huge
  local best_proj_t = target_proj_t

  local max_adjust_samples = (search_window_ms / 1000) * play_rate * sr * 0.5

  local idx = 1
  local prev_val = 0

  for i = 1, num_samples do
    local sum = 0
    for c = 1, num_channels do sum = sum + (t[idx] or 0); idx = idx + 1 end
    local val = sum / num_channels

    if i > 1 then
      if (prev_val <= 0 and val > 0) or (prev_val >= 0 and val < 0) then
        local fraction = math.abs(prev_val) / (math.abs(prev_val) + math.abs(val) + 1e-15)
        local exact_idx = (i - 1) + fraction
        local dist = math.abs(exact_idx - target_sample_idx)
        if dist < min_dist and dist <= max_adjust_samples then
          min_dist = dist
          local src_offset_sec = (exact_idx - 1) / sr
          best_proj_t = start_proj_t + src_offset_sec / play_rate
        end
      end
    end
    prev_val = val
  end

  local result_src_t = take_offset + (best_proj_t - item_pos) * play_rate
  local src_start = take_offset
  local src_end   = take_offset + item_len * play_rate
  if result_src_t < src_start or result_src_t > src_end then
    return target_src_t
  end

  return result_src_t 
end 
 
-------------------------------------------------------------------- 
-- FINGERPRINT 
-------------------------------------------------------------------- 
local function ReadAudioForFP(track, start_time, end_time, sr, take)
  return ReadTrackAudio(track, start_time, end_time, sr, 1, take)
end 
 
local function FP_Normalize(x) 
  local maxv = 0 
  for i = 1, #x do maxv = math.max(maxv, math.abs(x[i])) end 
  if maxv < 1e-9 then return x end 
  for i = 1, #x do x[i] = x[i] / maxv end 
  return x 
end 
 
local function FP_Envelope(x, smooth) 
  local out = {} 
  local prev = 0 
  for i = 1, #x do 
    local v = math.abs(x[i]) 
    prev = prev * smooth + v * (1 - smooth) 
    out[i] = prev 
  end 
  return out 
end 
 
local function FP_GetPeaks(x, percentile) 
  local sorted = {} 
  for i = 1, #x do sorted[i] = x[i] end 
  table.sort(sorted) 
  local cutoff = sorted[math.max(1, math.floor(#sorted * percentile))] 
  local peaks = {} 
  for i = 2, #x - 1 do 
    if x[i] > cutoff and x[i] > x[i-1] and x[i] > x[i+1] then 
      peaks[#peaks + 1] = i 
    end 
  end 
  return peaks 
end 
 
local function FP_Quant(x)  return math.floor(x / 3 + 0.5) end 
local function FP_QuantC(x) return math.floor(x / 6 + 0.5) end 
 
local FP_KEY_MULT = 1000000
local function FP_PackKey(a, b)
  if b >= FP_KEY_MULT or b <= -FP_KEY_MULT then
    b = math.max(-FP_KEY_MULT + 1, math.min(FP_KEY_MULT - 1, b))
  end
  return a * FP_KEY_MULT + b
end

local function FP_BuildHashes(peaks) 
  local hashes = {} 
  for i = 1, #peaks - 4 do 
    local a, b, c = peaks[i], peaks[i+2], peaks[i+4] 
    local dt1, dt2 = b - a, c - b 
    hashes[#hashes + 1] = {hash = FP_PackKey(FP_Quant(dt1), FP_Quant(dt2)), time = a}
    hashes[#hashes + 1] = {hash = FP_PackKey(FP_QuantC(dt1), FP_QuantC(dt2)), time = a}
  end 
  return hashes 
end 
 
local function FP_BuildIndex(hashes) 
  local index = {} 
  for i = 1, #hashes do 
    local h = hashes[i] 
    if not index[h.hash] then index[h.hash] = {} end 
    table.insert(index[h.hash], h.time) 
  end 
  return index 
end 
 
local function FP_BestOffset(votes)
  local best, best_score = nil, 0
  for k, v in pairs(votes) do
    local neighbor_support = (votes[k-1] or 0) + (votes[k+1] or 0)
    local score = v + 0.3 * neighbor_support
    if score > best_score then
      best_score = score
      best = k
    end
  end
  return best, best_score
end 
 
local function FP_Match(query_hashes, ref_index, max_shift_samples) 
  local votes = {} 
  local total = 0 
  for i = 1, #query_hashes do 
    local q = query_hashes[i] 
    local ref_times = ref_index[q.hash] 
    if ref_times then 
      for j = 1, #ref_times do 
        local offset = q.time - ref_times[j]  
        if math.abs(offset) <= max_shift_samples then 
          votes[offset] = (votes[offset] or 0) + 1 
          total = total + 1 
        end 
      end 
    end 
  end 
  local best_off, best_score = FP_BestOffset(votes) 
  return best_off, best_score, votes, total 
end 
 
local function FindFingerprintOffset(ref_audio, dub_audio, sr, max_shift_sec) 
  if not ref_audio or not dub_audio then return nil, 0 end 
  ref_audio = FP_Normalize(ref_audio) 
  dub_audio = FP_Normalize(dub_audio) 
  local ref_env = FP_Envelope(ref_audio, EXT.fp_smooth) 
  local dub_env = FP_Envelope(dub_audio, EXT.fp_smooth) 
  local ref_peaks = FP_GetPeaks(ref_env, EXT.fp_percentile) 
  local dub_peaks = FP_GetPeaks(dub_env, EXT.fp_percentile) 
  if #ref_peaks < 5 or #dub_peaks < 5 then return nil, 0 end 
  local ref_hashes = FP_BuildHashes(ref_peaks) 
  local dub_hashes = FP_BuildHashes(dub_peaks) 
  local ref_index = FP_BuildIndex(ref_hashes) 
  local offset, _, votes, total = FP_Match(dub_hashes, ref_index, max_shift_sec * sr) 
  if not offset then return nil, 0 end 
  local snr = (votes[offset] or 0) / ((total / 100) + 1e-6) 
  return offset / sr, snr / (1 + math.abs(math.log(snr + 1))), nil, total 
end 
 
-------------------------------------------------------------------- 
-- LECTURE ENVELOPPE MULTI-BANDE 4 VOIES (SUB, MID, HIGH-MID, AIR) + ZCR
-------------------------------------------------------------------- 
local function MakeBiquadCoeffs(filter_type, f_cut, sr)
  local w0 = 2 * math.pi * f_cut / sr
  local cos_w0, sin_w0 = math.cos(w0), math.sin(w0)
  local biq_Q = 0.7071067811865476
  local alpha = sin_w0 / (2 * biq_Q)
  local a0 = 1 + alpha
  local b0, b1, b2
  if filter_type == "LP" then
    b0 = (1 - cos_w0) / 2
    b1 = 1 - cos_w0
    b2 = (1 - cos_w0) / 2
  else -- "HP"
    b0 = (1 + cos_w0) / 2
    b1 = -(1 + cos_w0)
    b2 = (1 + cos_w0) / 2
  end
  local a1 = -2 * cos_w0
  local a2 = 1 - alpha
  return b0/a0, b1/a0, b2/a0, a1/a0, a2/a0
end

local function GetEnvelopeAnalysisSampleRate(source_sr)
  local requested = math.max(8000, math.min(16000, source_sr or 44100))
  return math.max(2000, math.floor(requested + 0.5))
end

local function GetEnvelopeSingleRange(track, take, item_pos, range_start, range_end, segment_id)
  local source = GetMediaItemTake_Source(take)
  if not source then return {} end
  local item = GetMediaItemTake_Item(take)
  if not item then return {} end

  item_pos = GetMediaItemInfo_Value(item, 'D_POSITION')
  local source_sr = GetMediaSourceSampleRate(source)
  if source_sr <= 0 then source_sr = 44100 end
  local sr = GetEnvelopeAnalysisSampleRate(source_sr)

  local take_offset = GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local play_rate = GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1.0
  if play_rate <= 0 then play_rate = 1.0 end
  if range_end <= range_start then return {} end

  local item_len = GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  local item_end = item_pos + item_len
  range_start = math.max(range_start, item_pos)
  range_end = math.min(range_end, item_end)
  if range_end <= range_start then return {} end

  local total_samples = math.max(1, math.ceil((range_end - range_start) * sr))
  local win = math.max(4, math.ceil(EXT.window_ms * sr / 1000))
  local hop = math.max(1, math.ceil(EXT.hop_ms * sr / 1000))
  if total_samples < win then return {} end

  local f_low  = math.min(math.max(50, EXT.split_freq_low),  sr * 0.12)
  local f_mid  = math.min(math.max(f_low * 1.5, EXT.split_freq_mid), sr * 0.30)
  local f_high = math.min(math.max(f_mid * 1.5, EXT.split_freq_high), sr * 0.42)

  local lp1_b0, lp1_b1, lp1_b2, lp1_a1, lp1_a2 = MakeBiquadCoeffs("LP", f_low, sr)
  local hp1_b0, hp1_b1, hp1_b2, hp1_a1, hp1_a2 = MakeBiquadCoeffs("HP", f_low, sr)
  local lp2_b0, lp2_b1, lp2_b2, lp2_a1, lp2_a2 = MakeBiquadCoeffs("LP", f_mid, sr)
  local hp2_b0, hp2_b1, hp2_b2, hp2_a1, hp2_a2 = MakeBiquadCoeffs("HP", f_mid, sr)
  local lp3_b0, lp3_b1, lp3_b2, lp3_a1, lp3_a2 = MakeBiquadCoeffs("LP", f_high, sr)
  local hp3_b0, hp3_b1, hp3_b2, hp3_a1, hp3_a2 = MakeBiquadCoeffs("HP", f_high, sr)

  local lp1_x1, lp1_x2, lp1_y1, lp1_y2 = 0, 0, 0, 0
  local hp1_x1, hp1_x2, hp1_y1, hp1_y2 = 0, 0, 0, 0
  local lp2_x1, lp2_x2, lp2_y1, lp2_y2 = 0, 0, 0, 0
  local hp2_x1, hp2_x2, hp2_y1, hp2_y2 = 0, 0, 0, 0
  local lp3_x1, lp3_x2, lp3_y1, lp3_y2 = 0, 0, 0, 0
  local hp3_x1, hp3_x2, hp3_y1, hp3_y2 = 0, 0, 0, 0

  local PRE_EMPHASIS_CUTOFF_HZ = math.min(1140, sr * 0.20)
  local alpha_pe = math.exp(-2 * math.pi * PRE_EMPHASIS_CUTOFF_HZ / sr)
  local prev_raw = 0

  local ring_b1, ring_b2, ring_b3, ring_b4, ring_x = {}, {}, {}, {}, {}
  local ring_pos = 0
  local count_in_ring = 0
  local sum_b1_sq, sum_b2_sq, sum_b3_sq, sum_b4_sq = 0, 0, 0, 0
  local sum_x = 0
  local last_rms_b4 = 0
  local last_rms_total = 0
  local env = {}

  local function ProcessSample(raw, absolute_sample_index)
    local x = EXT.use_pre_emphasis and (raw - alpha_pe * prev_raw) or raw
    prev_raw = raw

    local v_lp1 = lp1_b0*raw + lp1_b1*lp1_x1 + lp1_b2*lp1_x2 - lp1_a1*lp1_y1 - lp1_a2*lp1_y2
    lp1_x2 = lp1_x1; lp1_x1 = raw; lp1_y2 = lp1_y1; lp1_y1 = v_lp1
    local v_hp1 = hp1_b0*raw + hp1_b1*hp1_x1 + hp1_b2*hp1_x2 - hp1_a1*hp1_y1 - hp1_a2*hp1_y2
    hp1_x2 = hp1_x1; hp1_x1 = raw; hp1_y2 = hp1_y1; hp1_y1 = v_hp1

    local v_lp2 = lp2_b0*v_hp1 + lp2_b1*lp2_x1 + lp2_b2*lp2_x2 - lp2_a1*lp2_y1 - lp2_a2*lp2_y2
    lp2_x2 = lp2_x1; lp2_x1 = v_hp1; lp2_y2 = lp2_y1; lp2_y1 = v_lp2
    local v_hp2 = hp2_b0*v_hp1 + hp2_b1*hp2_x1 + hp2_b2*hp2_x2 - hp2_a1*hp2_y1 - hp2_a2*hp2_y2
    hp2_x2 = hp2_x1; hp2_x1 = v_hp1; hp2_y2 = hp2_y1; hp2_y1 = v_hp2

    local v_lp3 = lp3_b0*v_hp2 + lp3_b1*lp3_x1 + lp3_b2*lp3_x2 - lp3_a1*lp3_y1 - lp3_a2*lp3_y2
    lp3_x2 = lp3_x1; lp3_x1 = v_hp2; lp3_y2 = lp3_y1; lp3_y1 = v_lp3
    local v_hp3 = hp3_b0*v_hp2 + hp3_b1*hp3_x1 + hp3_b2*hp3_x2 - hp3_a1*hp3_y1 - hp3_a2*hp3_y2
    hp3_x2 = hp3_x1; hp3_x1 = v_hp2; hp3_y2 = hp3_y1; hp3_y1 = v_hp3

    ring_pos = (ring_pos % win) + 1
    if count_in_ring == win then
      local old1, old2, old3, old4, oldx = ring_b1[ring_pos] or 0, ring_b2[ring_pos] or 0, ring_b3[ring_pos] or 0, ring_b4[ring_pos] or 0, ring_x[ring_pos] or 0
      sum_b1_sq = sum_b1_sq - old1*old1
      sum_b2_sq = sum_b2_sq - old2*old2
      sum_b3_sq = sum_b3_sq - old3*old3
      sum_b4_sq = sum_b4_sq - old4*old4
      sum_x = sum_x - oldx
    else
      count_in_ring = count_in_ring + 1
    end

    ring_b1[ring_pos], ring_b2[ring_pos], ring_b3[ring_pos], ring_b4[ring_pos], ring_x[ring_pos] = v_lp1, v_lp2, v_lp3, v_hp3, x
    sum_b1_sq = sum_b1_sq + v_lp1*v_lp1
    sum_b2_sq = sum_b2_sq + v_lp2*v_lp2
    sum_b3_sq = sum_b3_sq + v_lp3*v_lp3
    sum_b4_sq = sum_b4_sq + v_hp3*v_hp3
    sum_x = sum_x + x

    if absolute_sample_index >= win and ((absolute_sample_index - win) % hop) == 0 then
      local n = win
      local dc = sum_x / n
      local zc = 0
      local prev_sign = nil
      local start_ring = (ring_pos % win) + 1
      for k = 0, win - 1 do
        local rp = ((start_ring - 1 + k) % win) + 1
        local val = (ring_x[rp] or 0) - dc
        local sign = val >= 0
        if prev_sign ~= nil and sign ~= prev_sign then zc = zc + 1 end
        prev_sign = sign
      end

      local rms_b1 = math.sqrt(math.max(0, sum_b1_sq / n))
      local rms_b2 = math.sqrt(math.max(0, sum_b2_sq / n))
      local rms_b3 = math.sqrt(math.max(0, sum_b3_sq / n))
      local rms_b4 = math.sqrt(math.max(0, sum_b4_sq / n))
      local zcr = zc / math.max(1, n - 1)
      local diff_b4 = rms_b4 - last_rms_b4
      local flux_high = diff_b4 > 0 and diff_b4 or 0
      last_rms_b4 = rms_b4
      local rms_total = rms_b1 + rms_b2 + rms_b3 + rms_b4
      local delta_rms = math.max(0, rms_total - last_rms_total)
      last_rms_total = rms_total

      local window_start_sample = absolute_sample_index - win
      local proj_t = range_start + window_start_sample / sr
      local src_t = take_offset + (proj_t - item_pos) * play_rate
      env[#env + 1] = {
        rms = rms_total, rms_low = rms_b1, flux_high = flux_high, zcr = zcr,
        rms_b1 = rms_b1, rms_b2 = rms_b2, rms_b3 = rms_b3, rms_b4 = rms_b4,
        delta_rms = delta_rms, proj_time = proj_t, src_time = src_t,
        is_blob = true, is_breath = false, segment_id = segment_id or 1,
      }
    end
  end

  local accessor = CreateTakeAudioAccessor(take)
  if not accessor then return {} end
  local chunk_sec = ClampParam(EXT.audio_read_chunk_sec, 0.25, 60.0, 8.0)
  local chunk_samples_max = math.max(1, math.floor(chunk_sec * sr + 0.5))
  local processed = 0
  local ok_read = true

  while processed < total_samples do
    local chunk_samples = math.min(chunk_samples_max, total_samples - processed)
    local buf = reaper.new_array(chunk_samples)
    local ret = GetAudioAccessorSamples(
      accessor, sr, 1,
      (range_start - item_pos) + processed / sr,
      chunk_samples, buf
    )
    if ret < 0 then
      ok_read = false
      break
    end
    for i = 1, chunk_samples do
      local raw = ret > 0 and (buf[i] or 0) or 0
      ProcessSample(raw, processed + i)
    end
    processed = processed + chunk_samples
  end
  DestroyAudioAccessor(accessor)

  if not ok_read then
    log(string.format("  [WARN] GetEnvelope: accessor read error in segment %d (%.3f..%.3f)", segment_id or 1, range_start, range_end))
    return {}
  end

  return env
end

local function GetEnvelope(track, take, item_pos, start_time, end_time, ranges)
  if not take or not ValidatePtr2(0, take, "MediaItem_Take*") then return {} end
  local source = GetMediaItemTake_Source(take)
  if not source then
    log("  [WARN] GetEnvelope: take has no source")
    return {}
  end

  local use_ranges = ranges
  if not use_ranges or #use_ranges == 0 then
    use_ranges = {{start = start_time, finish = end_time}}
  end

  local env = {}
  for seg_id, r in ipairs(use_ranges) do
    if r and r.start and r.finish and r.finish > r.start then
      local part = GetEnvelopeSingleRange(track, take, item_pos, r.start, r.finish, seg_id)
      for _, e in ipairs(part) do env[#env + 1] = e end
    end
  end

  if #env > 0 then
    local source_sr = GetMediaSourceSampleRate(source)
    if source_sr <= 0 then source_sr = 44100 end
    local sr = GetEnvelopeAnalysisSampleRate(source_sr)
    local win = math.max(4, math.ceil(EXT.window_ms * sr / 1000))
    local hop = math.max(1, math.ceil(EXT.hop_ms * sr / 1000))
    log(string.format("  [Envelope] analysis SR=%d Hz | window=%d | hop=%d | frames=%d | segments=%d", sr, win, hop, #env, #use_ranges))
  end
  return env
end

local function ReadWaveform(track, start_time, end_time, target_sr, take)
  local t = ReadTrackAudio(track, start_time, end_time, target_sr, 1, take)
  if not t then return {} end
  return t
end 
 
local function Smooth(env, field, window_ms)
  local n = #env
  if n < 3 then return end
  local radius = math.max(1, math.floor(window_ms / (2 * EXT.hop_ms)))

  local weights = _smooth_weights_cache[radius]
  local total_weight_sum
  if not weights then
    weights = {}
    total_weight_sum = 0
    for k = -radius, radius do
      weights[k] = math.exp(-(k*k) / (2 * (radius/2)^2))
      total_weight_sum = total_weight_sum + weights[k]
    end
    weights._sum = total_weight_sum
    _smooth_weights_cache[radius] = weights
  end
  total_weight_sum = weights._sum

  local out = {}
  for i = 1, n do
    local seg = env[i].segment_id
    local sum, current_w_sum = 0, 0
    for k = -radius, radius do
      local j = i + k
      if j >= 1 and j <= n and (seg == nil or env[j].segment_id == seg) then
        sum = sum + (env[j][field] or 0) * weights[k]
        current_w_sum = current_w_sum + weights[k]
      end
    end
    out[i] = current_w_sum > 0 and (sum / current_w_sum) or (env[i][field] or 0)
  end
  for i = 1, n do env[i][field] = out[i] end
end

-------------------------------------------------------------------- 
-- MODULE C : DÉTECTION & PROTECTION DES RESPIRATIONS
-------------------------------------------------------------------- 
local function MarkBreaths(env, name)
  if not EXT.enable_breath_protect or #env == 0 then return 0 end
  local breath_count = 0
  for i = 1, #env do
    local e = env[i]
    local is_b = (e.norm_b4 >= EXT.breath_air_min)
             and (e.norm_b1 <= EXT.breath_sub_max)
             and (e.norm_zcr >= EXT.breath_zcr_min)
             and (not e.gated)
    e.is_breath = is_b
    if is_b then breath_count = breath_count + 1 end
  end
  log(string.format("  [BreathProtect] %s : %d breath frames detected & protected", name, breath_count))
  return breath_count
end
 
-------------------------------------------------------------------- 
-- ÉTAPE 1.5 : SEGMENTATION VOCALE HYBRIDE 
-------------------------------------------------------------------- 
local function SegmentBlobs(env, name) 
  if not EXT.use_segmentation or #env == 0 then 
    for i = 1, #env do env[i].is_blob = true end 
    return 1 
  end 
 
  local rms_list = {}
  rms_list[#env] = false
  for i = 1, #env do rms_list[i] = env[i].rms end
  table.sort(rms_list) 
  local p10_idx = math.max(1, math.floor(#rms_list * 0.10)) 
  local noise_rms = rms_list[p10_idx] or 0.0001 
  local noise_db = val2db(noise_rms) 
  local adaptive_thresh_db = math.max(EXT.blob_thresh_min_db, math.min(EXT.blob_thresh_max_db, noise_db + 6)) 
   
  local max_flux = 0 
  for i = 1, #env do if env[i].flux_high > max_flux then max_flux = env[i].flux_high end end 
  if max_flux < 1e-9 then max_flux = 1.0 end 
   
  local raw_tonal = {} 
  for i = 1, #env do 
    local e = env[i] 
    local audible = val2db(e.rms) > adaptive_thresh_db 
    local low_zcr = e.zcr < EXT.zcr_threshold 
    local is_transient = (e.flux_high / max_flux) > EXT.transient_threshold 
    raw_tonal[i] = audible and (low_zcr or is_transient) 
    e.is_blob = false 
  end 
   
  local gap_blocks = math.ceil(EXT.blob_gap_ms / EXT.hop_ms) 
  local gap_blocks_extended = gap_blocks * 2
  local in_blob = false 
  local last_tonal_idx = -1000 
  local previous_segment = env[1] and env[1].segment_id or nil
  for i = 1, #env do 
    local current_segment = env[i].segment_id
    if i > 1 and current_segment ~= previous_segment then
      in_blob = false
      last_tonal_idx = -1000
    end
    previous_segment = current_segment
    if raw_tonal[i] then 
      if not in_blob and last_tonal_idx > 0 then
        local gap_len = i - last_tonal_idx
        local bridge = false
        if gap_len <= gap_blocks then
          bridge = true
        elseif gap_len <= gap_blocks_extended then
          local gap_sum_db, gap_n = 0, 0
          for j = last_tonal_idx + 1, i - 1 do
            gap_sum_db = gap_sum_db + val2db(env[j].rms); gap_n = gap_n + 1
          end
          if gap_n > 0 and (gap_sum_db / gap_n) > adaptive_thresh_db - 6 then
            bridge = true
          end
        end
        if bridge then
          for j = last_tonal_idx + 1, i - 1 do env[j].is_blob = true end
        end
      end 
      in_blob = true; env[i].is_blob = true; last_tonal_idx = i 
    else 
      if in_blob then in_blob = false end 
    end 
  end 
   
  local min_blocks = math.ceil(EXT.min_blob_ms / EXT.hop_ms) 
  local current_len, blob_count = 0, 0 
  for i = 1, #env do 
    if env[i].is_blob then current_len = current_len + 1 
    else 
      if current_len > 0 and current_len < min_blocks then 
        for j = i - current_len, i - 1 do env[j].is_blob = false end 
      elseif current_len >= min_blocks then blob_count = blob_count + 1 end 
      current_len = 0 
    end 
  end 
  if current_len >= min_blocks then blob_count = blob_count + 1 end 
   
  log(string.format("  [Segmentation] %s : Noise=%.1f dB | Threshold=%.1f dB | Blobs=%d", name, 
noise_db, adaptive_thresh_db, blob_count)) 
  if blob_count == 0 then
    log(string.format("  [WARN] %s: 0 blobs detected — item may be silent.", name))
  end
  return blob_count 
end 

--------------------------------------------------------------------
-- CONVERSION TEMPORELLE & SHIFT DÉPLACEMENT RÉEL
--------------------------------------------------------------------
local function ProjectTimeToSourceTime(take, proj_time)
  local item     = GetMediaItemTake_Item(take)
  local item_pos = GetMediaItemInfo_Value(item, 'D_POSITION')
  local t_offs   = GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  local t_rate   = GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  if not t_rate or t_rate <= 0 then t_rate = 1.0 end
  return t_offs + (proj_time - item_pos) * t_rate
end

local function SourceTimeToProjectTime(take, src_time)
  local item     = GetMediaItemTake_Item(take)
  local item_pos = GetMediaItemInfo_Value(item, 'D_POSITION')
  local t_offs   = GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  local t_rate   = GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  if not t_rate or t_rate <= 0 then t_rate = 1.0 end
  return item_pos + (src_time - t_offs) / t_rate
end

local function CapturedDubTimeToCurrentProjectTime(dub, captured_proj_time)
  return captured_proj_time + (dub.applied_rigid_shift or 0)
end

--------------------------------------------------------------------
-- FINE-TUNING CONSTANTS
--------------------------------------------------------------------
local ANCHOR_REFINE_RADIUS = 2

local function MicroAlignAnchor(track_ref, track_dub, ref_t, dub_t, search_window_sec,
target_sr, take_ref, take_dub)
  local window_sec    = search_window_sec
  local max_shift_sec = search_window_sec / 2

  local r_audio = ReadTrackAudio(track_ref, ref_t - window_sec/2, ref_t +
window_sec/2, target_sr, 1, take_ref)
  local d_audio = ReadTrackAudio(track_dub, dub_t - window_sec/2, dub_t +
window_sec/2, target_sr, 1, take_dub)
  if not r_audio or not d_audio or #r_audio < 10 or #d_audio < 10 then return 0 end 
   
  r_audio = ApplyHann(r_audio)
  d_audio = ApplyHann(d_audio)

  local lag_sec, corr = FindCorrelationOffset_FFT(r_audio, d_audio, target_sr, max_shift_sec)
  if corr > EXT.micro_corr_threshold then return lag_sec end 
  return 0 
end 
 
local function FindAdaptiveOffset(dub)
  local results = {}
  local fp_offset, fp_conf, fp_score, fp_total = FindFingerprintOffset(dub.fp_ref, dub.fp_dub, EXT.fp_sr, EXT.max_shift_sec)
  results.fingerprint = { offset = fp_offset or 0, score = fp_conf or 0, raw_score = fp_score, total = fp_total, valid = (fp_offset ~= nil) and (fp_conf or 0) > 0.1 }

  if results.fingerprint.valid then
    log(string.format("  [Macro] FP:  offset=%+.3fs  score=%.3f  votes=%d  valid=YES",
      results.fingerprint.offset, results.fingerprint.score, fp_total or 0))
  else
    log(string.format("  [Macro] FP:  offset=%+.3fs  score=%.3f  votes=%d  valid=NO (< 0.1 threshold)",
      results.fingerprint.offset, results.fingerprint.score, fp_total or 0))
  end

  local n_ref, n_dub = #dub.env_ref, #dub.env_dub
  local ref_arr, dub_arr = {}, {}
  ref_arr[n_ref] = false; dub_arr[n_dub] = false
  for i, e in ipairs(dub.env_ref) do ref_arr[i] = e.rms end
  for i, e in ipairs(dub.env_dub) do dub_arr[i] = e.rms end

  if #ref_arr < 4 or #dub_arr < 4 then
    log("  [WARN] Macro: envelope too short for reliable correlation")
  end

  local env_sr = 1000 / EXT.hop_ms
  local env_offset, env_score = FindCorrelationOffset_WLNCC(ref_arr, dub_arr, env_sr, EXT.max_shift_sec)
  results.envelope = { offset = env_offset or 0, score = env_score or 0, valid = (env_score or 0) > 0.1 }

  if results.envelope.valid then
    log(string.format("  [Macro] ENV: offset=%+.3fs  score=%.3f  valid=YES", results.envelope.offset, results.envelope.score))
  else
    log(string.format("  [Macro] ENV: offset=%+.3fs  score=%.3f  valid=NO", results.envelope.offset, results.envelope.score))
  end

  local coarse_offset = nil
  if results.fingerprint.valid then
    coarse_offset = results.fingerprint.offset
  elseif results.envelope.valid then
    coarse_offset = results.envelope.offset
  end

  if not dub.wf_ref or #dub.wf_ref < 4 or not dub.wf_dub or #dub.wf_dub < 4 then
    log("  [WARN] Macro: waveform buffer empty or too short — WF step skipped")
  end

  local wf_offset, wf_score
  if coarse_offset then
    wf_offset, wf_score = FindCorrelationOffset_WLNCC(
      dub.wf_ref, dub.wf_dub, EXT.wf_sr, EXT.max_shift_sec,
      coarse_offset, EXT.wf_refine_radius_sec
    )
    log(string.format("  [Macro] WF:  coarse=%+.3fs → refine ±%.3fs → offset=%+.3fs  score=%.3f",
      coarse_offset, EXT.wf_refine_radius_sec, wf_offset or 0, wf_score or 0))
  else
    wf_offset, wf_score = FindCorrelationOffset_WLNCC(dub.wf_ref, dub.wf_dub, EXT.wf_sr, EXT.max_shift_sec)
    log(string.format("  [WARN] Macro: no coarse estimate → WF full-range search → offset=%+.3fs  score=%.3f",
      wf_offset or 0, wf_score or 0))
  end
  results.waveform = { offset = wf_offset or 0, score = wf_score or 0, valid = (wf_score or 0) > 0.1 }

  if EXT.method == "FINGERPRINT" then
    log(string.format("  [Macro] → FINGERPRINT (forced): offset=%+.3fs  score=%.3f", results.fingerprint.offset, results.fingerprint.score))
    return results.fingerprint.offset, results.fingerprint.score, "FINGERPRINT (forced)", results
  elseif EXT.method == "WAVEFORM" then
    log(string.format("  [Macro] → WAVEFORM (forced): offset=%+.3fs  score=%.3f", results.waveform.offset, results.waveform.score))
    return results.waveform.offset, results.waveform.score, "WAVEFORM (forced)", results
  elseif EXT.method == "ENVELOPE" then
    log(string.format("  [Macro] → ENVELOPE (forced): offset=%+.3fs  score=%.3f", results.envelope.offset, results.envelope.score))
    return results.envelope.offset, results.envelope.score, "ENVELOPE (forced)", results
  end

  local CONSENSUS_THRESHOLD = math.min(0.100, math.max(0.020, (dub.len or 10) * 0.02))
  local fp, wf, env = results.fingerprint, results.waveform, results.envelope

  local chosen_offset, chosen_score, chosen_method
  if fp.valid and wf.valid and env.valid
      and math.abs(fp.offset - wf.offset) < CONSENSUS_THRESHOLD
      and math.abs(wf.offset - env.offset) < CONSENSUS_THRESHOLD then
    chosen_offset, chosen_score, chosen_method = wf.offset, wf.score, "WAVEFORM (total consensus)"
  elseif wf.valid and env.valid and math.abs(wf.offset - env.offset) < CONSENSUS_THRESHOLD then
    chosen_method = wf.score > 0.5 and "WAVEFORM (high precision)" or "WAVEFORM (consensus)"
    chosen_offset, chosen_score = wf.offset, wf.score
  elseif fp.valid and wf.valid and math.abs(fp.offset - wf.offset) < CONSENSUS_THRESHOLD then
    chosen_offset, chosen_score, chosen_method = wf.offset, wf.score, "WAVEFORM (validated fingerprint)"
  elseif fp.valid and env.valid and math.abs(fp.offset - env.offset) < CONSENSUS_THRESHOLD then
    chosen_offset, chosen_score, chosen_method = fp.offset, fp.score, "FINGERPRINT (different tracks)"
  elseif fp.valid then
    chosen_offset, chosen_score, chosen_method = fp.offset, fp.score, "FINGERPRINT (robust)"
  elseif wf.valid and wf.score > 0.3 then
    chosen_offset, chosen_score, chosen_method = wf.offset, wf.score, "WAVEFORM (fallback)"
  elseif env.valid then
    chosen_offset, chosen_score, chosen_method = env.offset, env.score, "ENVELOPE (fallback)"
  else
    chosen_offset, chosen_score, chosen_method = 0, 0, "FAILED (no method)"
  end

  log(string.format("  [Macro] → %s: offset=%+.3fs  score=%.3f", chosen_method, chosen_offset, chosen_score))
  return chosen_offset, chosen_score, chosen_method, results
end 
 
local function NormalizeCommon(env, common_max_db, gate_db)
  if not env or #env == 0 then return end
  if not IsFiniteNumber(common_max_db) then common_max_db = -200 end
  if common_max_db <= -150 then
    for i = 1, #env do
      env[i].rms_db = -200
      env[i].norm_b1, env[i].norm_b2, env[i].norm_b3, env[i].norm_b4 = 0, 0, 0, 0
      env[i].norm_low, env[i].norm_flux, env[i].norm_delta, env[i].norm_zcr, env[i].gated = 0, 0, 0, 0, true
    end
    log("  [WARN] NormalizeCommon: signal appears silent")
    return
  end

  local gate_abs = common_max_db + gate_db
  local denom = math.max(1e-6, common_max_db - gate_abs)

  for i = 1, #env do env[i].rms_db = val2db(env[i].rms) end

  local max_flux = 0
  local max_delta = 0
  for i = 1, #env do
    if env[i].rms_db >= gate_abs then
      if env[i].flux_high  > max_flux  then max_flux  = env[i].flux_high  end
      if (env[i].delta_rms or 0) > max_delta then max_delta = env[i].delta_rms end
    end
  end
  if max_flux  < 1e-9 then max_flux  = 1.0 end
  if max_delta < 1e-9 then max_delta = 1.0 end

  for i = 1, #env do
    if env[i].rms_db < gate_abs then
      env[i].norm_b1, env[i].norm_b2, env[i].norm_b3, env[i].norm_b4 = 0, 0, 0, 0
      env[i].norm_low, env[i].norm_flux, env[i].norm_delta, env[i].norm_zcr, env[i].gated = 0, 0, 0, 0, true
    else
      local db_b1 = val2db(env[i].rms_b1 or 0)
      local db_b2 = val2db(env[i].rms_b2 or 0)
      local db_b3 = val2db(env[i].rms_b3 or 0)
      local db_b4 = val2db(env[i].rms_b4 or 0)

      env[i].norm_b1 = math.max(0.0, math.min(1.0, (db_b1 - gate_abs) / denom))
      env[i].norm_b2 = math.max(0.0, math.min(1.0, (db_b2 - gate_abs) / denom))
      env[i].norm_b3 = math.max(0.0, math.min(1.0, (db_b3 - gate_abs) / denom))
      env[i].norm_b4 = math.max(0.0, math.min(1.0, (db_b4 - gate_abs) / denom))

      local flux_val = env[i].flux_high / max_flux
      env[i].norm_low   = env[i].norm_b1
      env[i].norm_flux  = math.max(0.0, math.min(1.0, flux_val))
      env[i].norm_delta = math.max(0.0, math.min(1.0, (env[i].delta_rms or 0) / max_delta))
      env[i].norm_zcr   = math.max(0.0, math.min(1.0, env[i].zcr or 0))
      env[i].gated = false
    end
  end
end 

local function SubsampleEnv(env, factor)
  local out = {}
  for i = 1, #env, factor do
    out[#out + 1] = env[i]
  end
  return out
end

local function InterpolateCoarsePath(path_coarse, factor, N_fine, M_fine)
  local known = {}
  local seen = {}
  for _, pt in ipairs(path_coarse) do
    local i_fine = math.min(N_fine, math.max(1, 1 + (pt.r - 1) * factor))
    local j_fine = math.min(M_fine, math.max(1, 1 + (pt.d - 1) * factor))
    if not seen[i_fine] then
      known[#known + 1] = { i = i_fine, j = j_fine }
      seen[i_fine] = true
    end
  end
  table.sort(known, function(a, b) return a.i < b.i end)

  local guide = {}
  if #known == 0 then return guide end

  for i = 1, known[1].i do guide[i] = known[1].j end

  for k = 1, #known - 1 do
    local p1, p2 = known[k], known[k+1]
    guide[p1.i] = p1.j
    for i = p1.i + 1, p2.i - 1 do
      local frac = (i - p1.i) / (p2.i - p1.i)
      guide[i] = math.floor(p1.j + (p2.j - p1.j) * frac + 0.5)
    end
    guide[p2.i] = p2.j
  end

  local last = known[#known]
  for i = last.i, N_fine do
    if not guide[i] then guide[i] = last.j end
  end

  return guide
end
 
-------------------------------------------------------------------- 
-- DTW LOCAL CHUNKED MULTI-FEATURE (4-BANDE + BANDE D'ITAKURA + BREATH PENALTY) 
-------------------------------------------------------------------- 
local DTW_CHUNK_SIZE = 45
local DTW_CHUNK_TIME_BUDGET_SEC = 0.012
 
local function ComputeLocalDTW_Chunked(ref_env, dub_env, global_offset_sec, existing_state, guide, override_band, hop_ms_effective, keep_mat)
  local N, M = #ref_env, #dub_env
  if N == 0 or M == 0 then return nil, nil end
  local state = existing_state or {}

  if not state.initialized then
    local hop_ms_used = hop_ms_effective or EXT.hop_ms
    state.offset_idx = math.floor(global_offset_sec * 1000 / hop_ms_used + 0.5)
    state.band = override_band or math.floor(EXT.dtw_band_ms / hop_ms_used)
    state.guide = guide
    state.N, state.M = N, M
    state.stride = M + 1
    state.mat = {}
    state.row_bounds = {}
    state.dir = {}
    state.current_i = 1

    state.w_b1 = 0.15 
    state.w_b2 = 0.30 
    state.w_b3 = 0.25 
    state.w_b4 = 0.15 
    state.w_delta = math.max(0, EXT.dtw_delta_weight)
    state.w_zcr   = math.max(0, EXT.dtw_zcr_weight)
    state.w_flux  = math.max(0, EXT.dtw_feature_weight)

    local total_w = state.w_b1 + state.w_b2 + state.w_b3 + state.w_b4 + state.w_delta + state.w_zcr + state.w_flux
    if total_w < 1e-9 then total_w = 1.0 end
    state.w_b1    = state.w_b1 / total_w
    state.w_b2    = state.w_b2 / total_w
    state.w_b3    = state.w_b3 / total_w
    state.w_b4    = state.w_b4 / total_w
    state.w_delta = state.w_delta / total_w
    state.w_zcr   = state.w_zcr / total_w
    state.w_flux  = state.w_flux / total_w

    state.keep_mat    = (keep_mat == true)
    state.initialized = true
  end

  local w_b1    = state.w_b1
  local w_b2    = state.w_b2
  local w_b3    = state.w_b3
  local w_b4    = state.w_b4
  local w_delta = state.w_delta
  local w_zcr   = state.w_zcr
  local w_flux  = state.w_flux

  local S = math.max(1.05, EXT.max_stretch_ratio) 
   
  local function dist(a, b)  
    local d_b1    = (a.norm_b1 or 0) - (b.norm_b1 or 0) 
    local d_b2    = (a.norm_b2 or 0) - (b.norm_b2 or 0) 
    local d_b3    = (a.norm_b3 or 0) - (b.norm_b3 or 0) 
    local d_b4    = (a.norm_b4 or 0) - (b.norm_b4 or 0) 
    local d_flux  = (a.norm_flux or 0) - (b.norm_flux or 0) 
    local d_delta = (a.norm_delta or 0) - (b.norm_delta or 0)
    local d_zcr   = (a.norm_zcr or 0) - (b.norm_zcr or 0)

    local d_base = w_b1 * (d_b1 * d_b1) + w_b2 * (d_b2 * d_b2)
                 + w_b3 * (d_b3 * d_b3) + w_b4 * (d_b4 * d_b4)
                 + w_flux * (d_flux * d_flux) + w_delta * (d_delta * d_delta)
                 + w_zcr * (d_zcr * d_zcr)

    if EXT.use_segmentation and (a.is_blob ~= b.is_blob) then d_base = d_base + 5.0 end 
    
    -- Module C: Breath Protection Penalty
    if EXT.enable_breath_protect and (a.is_breath or b.is_breath) and (a.is_breath ~= b.is_breath) then
      d_base = d_base + 8.0
    end

    return d_base 
  end 
   
  local function get_mat(i, j) 
    if i < 1 or j < 1 then return math.huge end 
    return state.mat[i * state.stride + j] or math.huge
  end 
   
  local i = state.current_i 
  local chunk_end = math.min(N, i + DTW_CHUNK_SIZE - 1) 
  local t_chunk_start = time_precise()
   
  while i <= chunk_end do 
    local center_j
    if state.guide then
      center_j = state.guide[i] or (i + state.offset_idx)
    else
      center_j = i + state.offset_idx
    end

    -- Fix v15.2: le centre est borné, et Itakura n'est utilisé que sans guide et
    -- sans décalage macro (sinon le parallélogramme ancré en (1,1)-(N,M) exclut
    -- le vrai chemin et la matrice entière reste à +inf).
    center_j = math.max(1, math.min(M, center_j))
    local use_ita = (not state.guide) and math.abs(state.offset_idx) <= 2
    local j_ita_min = use_ita and math.max(1, math.floor(i / S), math.floor(M - S * (N - i))) or 1
    local j_ita_max = use_ita and math.min(M, math.ceil(S * i), math.ceil(M - (1 / S) * (N - i))) or M

    local jmin = math.max(1, center_j - state.band, j_ita_min) 
    local jmax = math.min(M, center_j + state.band, j_ita_max) 
    if jmin > jmax then local c = math.max(1, math.min(M, center_j)); jmin, jmax = c, c end

    local stride = state.stride
    local row_base = i * stride

    for j = jmin, jmax do
      local d = dist(ref_env[i], dub_env[j])
      local key = row_base + j
      
      if i == 1 and j == 1 then
        state.mat[key] = d
        state.dir[key] = 1
      elseif i == 1 then
        -- CORRECTION 1 : Ancrage fort au départ pour verrouiller l'extrémité initiale
        local start_j = state.guide and state.guide[1] or math.max(1, 1 + state.offset_idx)
        local dist_from_start = math.abs(j - start_j)
        state.mat[key] = d + (dist_from_start * 2.0)
        state.dir[key] = 1
      elseif j == 1 then
        local prev = get_mat(i - 1, 1)
        local ref_gated = ref_env[i] and ref_env[i].gated
        local penalty_up = ref_gated and (EXT.dtw_slope_penalty * 0.15) or EXT.dtw_slope_penalty
        state.mat[key] = (prev < math.huge) and (prev + d + penalty_up) or math.huge
        state.dir[key] = 3
      else
        local prev = get_mat(i-1, j)
        local left = get_mat(i, j-1)
        local diag = get_mat(i-1, j-1)

        local ref_gated = ref_env[i] and ref_env[i].gated
        local dub_gated = dub_env[j] and dub_env[j].gated
        local penalty_left = ref_gated and (EXT.dtw_slope_penalty * 0.15) or EXT.dtw_slope_penalty
        local penalty_up   = dub_gated and (EXT.dtw_slope_penalty * 0.15) or EXT.dtw_slope_penalty

        local prev_dir_left = state.dir[i * stride + (j - 1)]
        local prev_dir_up   = state.dir[(i - 1) * stride + j]
        if prev_dir_left == 2 then penalty_left = penalty_left * 2.2 end
        if prev_dir_up   == 3 then penalty_up   = penalty_up   * 2.2 end

        local cost_diag = diag
        local cost_left = left + penalty_left
        local cost_up   = prev + penalty_up

        local min_prev = cost_diag
        local best_dir = 1
        if cost_left < min_prev then min_prev = cost_left; best_dir = 2 end
        if cost_up   < min_prev then min_prev = cost_up;   best_dir = 3 end

        if min_prev < math.huge then state.mat[key] = d + min_prev else state.mat[key] = math.huge end
        state.dir[key] = best_dir
      end
    end

    state.row_bounds[i] = { jmin, jmax }
    if i > 2 then
      local prune_bounds = state.row_bounds[i - 2]
      if prune_bounds then
        local prune_base = (i - 2) * stride
        for jj = prune_bounds[1], prune_bounds[2] do
          state.mat[prune_base + jj] = nil
        end
        state.row_bounds[i - 2] = nil
      end
    end
    i = i + 1
    if time_precise() - t_chunk_start > DTW_CHUNK_TIME_BUDGET_SEC then break end 
  end 
  state.current_i = i 
   
  if i > N then 
    local best_i, best_j = N, 1
    local best_cost = math.huge
    local row_N_base = N * state.stride
    local row_N_bounds = state.row_bounds[N]
    
    -- CORRECTION 2 : Pénalisation de l'écart à la fin théorique pour éviter le décalage à la fin
    local target_j_end = state.guide and state.guide[N] or math.min(M, N + state.offset_idx)
    if row_N_bounds then
      for j = row_N_bounds[1], row_N_bounds[2] do
        local raw_cost = state.mat[row_N_base + j] or math.huge
        local end_penalty = math.abs(j - target_j_end) * 0.5
        local total_cost = raw_cost + end_penalty
        if total_cost < best_cost then
          best_cost = total_cost
          best_j = j
        end
      end
    end
     
    local ii, jj = best_i, best_j
    local path_rev = {}
    local path_len = 0
    
    -- CORRECTION 3 : Clôture propre du chemin de backtracking jusqu'à (1, 1) sans saut abrupt
    while ii >= 1 and jj >= 1 do
      path_len = path_len + 1
      path_rev[path_len] = {r = ii, d = jj}
      
      if ii == 1 and jj == 1 then break end
      
      if ii == 1 then
        jj = jj - 1
      elseif jj == 1 then
        ii = ii - 1
      else
        local d = state.dir[ii * state.stride + jj]
        if d == 1 then ii, jj = ii - 1, jj - 1
        elseif d == 2 then jj = jj - 1
        elseif d == 3 then ii = ii - 1
        else ii, jj = ii - 1, jj - 1
        end
      end
    end

    local path = {}
    for k = 1, path_len do path[k] = path_rev[path_len - k + 1] end
    return path, nil 
  end 
  return nil, state 
end 
 
local function RefineAnchorTime(env, idx, field, radius, seek_min) 
  local flux_at_idx = env[idx] and (env[idx].flux_high or 0) or 0
  local delta_at_idx = env[idx] and (env[idx].delta_rms or 0) or 0
  local use_field = field
  if use_field == "flux_high" and flux_at_idx < 0.05 and delta_at_idx > flux_at_idx * 1.5 then
    use_field = "delta_rms"
  end

  local best_i = idx
  local best_v = -math.huge 
  for i = math.max(2, idx - radius), math.min(#env - 1, idx + radius) do 
    local v = env[i][use_field] or 0 
    if v > best_v then best_v = v; best_i = i end 
  end 

  if best_v < 1e-6 then
    if seek_min then
      local min_i, min_v = idx, math.huge
      for i = math.max(2, idx - radius), math.min(#env - 1, idx + radius) do
        local v = env[i]["rms_low"] or math.huge
        if v < min_v then min_v = v; min_i = i end
      end
      if min_v < math.huge then
        local y1 = env[min_i - 1] and env[min_i - 1]["rms_low"] or min_v
        local y2 = env[min_i]["rms_low"] or min_v
        local y3 = env[min_i + 1] and env[min_i + 1]["rms_low"] or min_v
        local frac = ParabolicPeak(-y1, -y2, -y3)
        frac = math.max(-0.5, math.min(0.5, frac))
        return env[min_i].proj_time + frac * EXT.hop_ms / 1000
      end
    end
    return env[idx].proj_time
  end
   
  local y1 = env[best_i - 1] and env[best_i - 1][use_field] or best_v 
  local y2 = env[best_i][use_field] or best_v 
  local y3 = env[best_i + 1] and env[best_i + 1][use_field] or best_v 
  local frac = ParabolicPeak(y1, y2, y3) 
  frac = math.max(-0.5, math.min(0.5, frac)) 
  return env[best_i].proj_time + frac * EXT.hop_ms / 1000 
end 
 
-- ExtractAnchors avec vérification physique de drift et protection des respirations
local function ExtractAnchors(path, ref_env, dub_env, dub)
  local anchors = {}
  local min_gap = EXT.marker_min_gap_ms / 1000
  local last_ref_t = (ref_env[1] and ref_env[1].proj_time or 0) - min_gap
  local n_rejected_drift  = 0
  local n_rejected_conf   = 0
  local n_rejected_gap    = 0
  local n_rejected_nodub  = 0
  local n_rejected_breath = 0
   
  if #path >= 1 then
    local first = path[1]
    local r, d = ref_env[first.r], dub_env[first.d]
    if r and d and r.is_blob and d.is_blob then
      if not (EXT.enable_breath_protect and (r.is_breath or d.is_breath)) then
        local ref_t = RefineAnchorTime(ref_env, first.r, "flux_high", ANCHOR_REFINE_RADIUS)
        local dub_t = RefineAnchorTime(dub_env, first.d, "flux_high", ANCHOR_REFINE_RADIUS)
        local dub_proj_now = CapturedDubTimeToCurrentProjectTime(dub, dub_t)
        local drift = ref_t - dub_proj_now
        if math.abs(drift) <= EXT.drift_tolerance_sec * 2.0 then
          table.insert(anchors, {ref_t = ref_t, dub_t = dub_t, delta = drift, type = "START", conf = 1.0})
          last_ref_t = ref_t
        else
          if EXT.debug_mode then
            log(string.format("    ✗ START anchor drift rejected (drift=%.3fs, tol=%.3fs)", drift, EXT.drift_tolerance_sec * 2.0))
          end
        end
      else
        n_rejected_breath = n_rejected_breath + 1
      end
    end
  end 
   
  for k = 2, #path do 
    local curr, prev = path[k], path[k-1] 
    local r, d = ref_env[curr.r], dub_env[curr.d] 
    if r and d and not r.gated and not d.gated and r.is_blob and d.is_blob then 
      if EXT.enable_breath_protect and (r.is_breath or d.is_breath) then
        n_rejected_breath = n_rejected_breath + 1
      else
        local d_ref = r.rms_db - ref_env[prev.r].rms_db 
        
        if d_ref >= EXT.onset_thr_db then 
          local d_dub = d.rms_db - dub_env[prev.d].rms_db
          if d_dub >= (EXT.onset_thr_db * 0.4) then
            local flux_score   = math.min(1.0, (r.norm_flux  or 0))
            local energy_score = math.min(1.0, (r.norm_low   or 0))
            local delta_score  = math.min(1.0, (r.norm_delta or 0))
            local anchor_conf  = 0.5 * flux_score + 0.2 * energy_score + 0.3 * delta_score

            if anchor_conf >= EXT.anchor_min_conf then
              local ref_t = RefineAnchorTime(ref_env, curr.r, "flux_high", ANCHOR_REFINE_RADIUS)
              local dub_t = RefineAnchorTime(dub_env, curr.d, "flux_high", ANCHOR_REFINE_RADIUS)
              local dub_proj_now = CapturedDubTimeToCurrentProjectTime(dub, dub_t)
              local drift = ref_t - dub_proj_now

              if math.abs(drift) <= EXT.drift_tolerance_sec then
                if (ref_t - last_ref_t) >= min_gap then
                  table.insert(anchors, {ref_t = ref_t, dub_t = dub_t, delta = drift, type = "ONSET", conf = anchor_conf})
                  last_ref_t = ref_t
                else
                  n_rejected_gap = n_rejected_gap + 1
                end
              else
                n_rejected_drift = n_rejected_drift + 1
                if EXT.debug_mode then
                  log(string.format("    ✗ Drift rejected @%.3fs (drift=%.3fs, max=%.3fs)", ref_t, drift, EXT.drift_tolerance_sec))
                end
              end
            else
              n_rejected_conf = n_rejected_conf + 1
            end
          else
            n_rejected_nodub = n_rejected_nodub + 1
          end
        end
      end 
    end 
  end 
   
  if #path >= 1 then 
    local last = path[#path] 
    local r, d = ref_env[last.r], dub_env[last.d] 
    if r and d and r.is_blob and d.is_blob then 
      if not (EXT.enable_breath_protect and (r.is_breath or d.is_breath)) then
        local ref_t = RefineAnchorTime(ref_env, last.r, "flux_high", ANCHOR_REFINE_RADIUS, true) 
        local dub_t = RefineAnchorTime(dub_env, last.d, "flux_high", ANCHOR_REFINE_RADIUS, true) 
        local dub_proj_now = CapturedDubTimeToCurrentProjectTime(dub, dub_t)
        local drift = ref_t - dub_proj_now
        if math.abs(drift) <= EXT.drift_tolerance_sec * 1.5 then
          if (ref_t - last_ref_t) >= min_gap then 
            table.insert(anchors, {ref_t = ref_t, dub_t = dub_t, delta = drift, type = "END", conf = 1.0}) 
          end 
        else
          if EXT.debug_mode then
            log(string.format("    ✗ Drift rejected END @%.3fs (drift=%.3fs)", ref_t, drift))
          end
        end
      else
        n_rejected_breath = n_rejected_breath + 1
      end
    end 
  end 
  
  local has_start, has_end = false, false
  local n_onset, n_start, n_end, n_ghost = 0, 0, 0, 0
  for _, a in ipairs(anchors) do
    if a.type == "START" then has_start = true; n_start = n_start + 1
    elseif a.type == "END" then has_end = true; n_end = n_end + 1
    elseif a.type == "ONSET" then n_onset = n_onset + 1
    elseif a.type == "GHOST_START" or a.type == "GHOST_END" then n_ghost = n_ghost + 1
    end
  end

  if not has_start and #ref_env > 0 and #dub_env > 0 then
    local dub_t0 = dub_env[1].proj_time
    local dub_proj0 = CapturedDubTimeToCurrentProjectTime(dub, dub_t0)
    table.insert(anchors, 1, {
      ref_t = dub_proj0,
      dub_t = dub_t0,
      delta = 0,
      type = "GHOST_START", conf = 0.0
    })
    n_ghost = n_ghost + 1
    if EXT.debug_mode then log(string.format("    ℹ Ghost anchor START injected @%.3fs", dub_proj0)) end
  end

  if not has_end and #ref_env > 0 and #dub_env > 0 then
    local dub_tN = dub_env[#dub_env].proj_time
    local dub_projN = CapturedDubTimeToCurrentProjectTime(dub, dub_tN)
    table.insert(anchors, {
      ref_t = dub_projN,
      dub_t = dub_tN,
      delta = 0,
      type = "GHOST_END", conf = 0.0
    })
    n_ghost = n_ghost + 1
    if EXT.debug_mode then log(string.format("    ℹ Ghost anchor END injected @%.3fs", dub_projN)) end
  end

  log(string.format("  [Anchors] START=%d ONSET=%d END=%d GHOST=%d | Rejected: drift=%d conf=%d gap=%d nodub=%d breath=%d",
    n_start, n_onset, n_end, n_ghost, n_rejected_drift, n_rejected_conf, n_rejected_gap, n_rejected_nodub, n_rejected_breath))

  return anchors
end 
 
-------------------------------------------------------------------- 
-- CAPTURE DE SIGNAL AUDIO 
-------------------------------------------------------------------- 
local function NormalizeAndMergeRanges(ranges, item_pos, item_len)
  if not ranges or #ranges == 0 then return {} end
  local item_end = item_pos + item_len
  local cleaned = {}
  local min_active = ClampParam(EXT.analysis_min_active_ms, 10, 2000, 35) / 1000
  for _, r in ipairs(ranges) do
    if r and IsFiniteNumber(r.start) and IsFiniteNumber(r.finish) then
      local a = math.max(item_pos, r.start)
      local b = math.min(item_end, r.finish)
      if b - a >= min_active then
        cleaned[#cleaned + 1] = {start = a, finish = b}
      end
    end
  end
  table.sort(cleaned, function(a,b) return a.start < b.start end)
  if #cleaned <= 1 then return cleaned end

  local merge_gap = ClampParam(EXT.analysis_merge_gap_ms, 20, 2000, 180) / 1000
  local merged = { {start = cleaned[1].start, finish = cleaned[1].finish} }
  for i = 2, #cleaned do
    local last = merged[#merged]
    local cur = cleaned[i]
    if cur.start - last.finish <= merge_gap then
      last.finish = math.max(last.finish, cur.finish)
    else
      merged[#merged + 1] = {start = cur.start, finish = cur.finish}
    end
  end
  return merged
end

local function PadActiveRanges(ranges, item_pos, item_len)
  local padding = ClampParam(EXT.analysis_padding_ms, 0, 2000, 250) / 1000
  local item_end = item_pos + item_len
  local out = {}
  for _, r in ipairs(ranges or {}) do
    local a = math.max(item_pos, r.start - padding)
    local b = math.min(item_end, r.finish + padding)
    if b > a then out[#out + 1] = {start = a, finish = b} end
  end
  return out
end

local function RangeStats(ranges)
  local total = 0
  for _, r in ipairs(ranges or {}) do total = total + math.max(0, r.finish - r.start) end
  return total
end

local function DetectActiveAudioBounds_AccessorFallback(take, item_pos, item_len, attack, release)
  if not take or not ValidatePtr2(0, take, "MediaItem_Take*") then return nil end
  local track = GetMediaItemTake_Track(take) or GetMediaItem_Track(GetMediaItemTake_Item(take))
  if not track then return nil end

  local scan_sr = 2000
  local chunk_sec = 4.0
  local accessor = CreateTakeAudioAccessor(take)
  if not accessor then return nil end

  local ranges = {}
  local active_start = nil
  local active_state = false
  local cursor = 0.0
  local guard = 0

  local function close_range(end_t)
    if active_start then
      local b = math.min(item_pos + item_len, end_t)
      if b > active_start then ranges[#ranges + 1] = {start = active_start, finish = b} end
    end
    active_start = nil
    active_state = false
  end

  while cursor < item_len - 1e-9 do
    guard = guard + 1
    if guard > 100000 then break end
    local chunk_dur = math.min(chunk_sec, item_len - cursor)
    local n = math.max(1, math.ceil(chunk_dur * scan_sr))
    local buf = reaper.new_array(n)
    local ret = GetAudioAccessorSamples(accessor, scan_sr, 1, cursor, n, buf)
    if ret < 0 then
      DestroyAudioAccessor(accessor)
      return nil
    end

    for i = 1, n do
      local v = ret > 0 and math.abs(buf[i] or 0) or 0
      local proj_t = item_pos + cursor + (i - 1) / scan_sr
      if not active_state then
        if v >= attack then
          active_state = true
          active_start = proj_t
        end
      elseif v >= release then
        -- remain active under the release threshold model
      else
        close_range(proj_t)
      end
    end
    cursor = cursor + chunk_dur
  end
  if active_state then close_range(item_pos + item_len) end
  DestroyAudioAccessor(accessor)

  local merged = NormalizeAndMergeRanges(ranges, item_pos, item_len)
  if #merged == 0 then return nil end
  return merged
end

local function DetectActiveAudioBounds(take, item_pos, item_len)
  if not EXT.auto_trim_analysis then
    local full = {start = item_pos, finish = item_pos + item_len}
    return {
      start = item_pos, finish = item_pos + item_len,
      active_start = item_pos, active_end = item_pos + item_len,
      active_ratio = 1.0, scanned = false, fallback = false,
      active_ranges = {full}, ranges = {full},
      analysis_duration = item_len,
    }
  end

  if not take or not ValidatePtr2(0, take, "MediaItem_Take*") then return nil end
  if item_len <= 0 then return nil end

  local scan_rate = math.floor(ClampParam(EXT.analysis_scan_rate, 20, 500, 100) + 0.5)
  local attack_db = ClampParam(EXT.analysis_threshold_db, -100, -20, -60)
  local release_db = ClampParam(EXT.analysis_release_db, -110, -20, -66)
  if release_db > attack_db then release_db = attack_db - 1.0 end
  local attack = 10 ^ (attack_db / 20)
  local release = 10 ^ (release_db / 20)

  local raw_ranges = {}
  local active_start = nil
  local active_state = false
  local cursor = item_pos
  local scan_end = item_pos + item_len
  local peak_api_available = type(GetMediaItemTake_Peaks) == "function"
  local peak_api_had_data = false
  local guard = 0

  local function close_range(end_t)
    if active_start then
      local b = math.min(scan_end, end_t)
      if b > active_start then raw_ranges[#raw_ranges + 1] = {start = active_start, finish = b} end
    end
    active_start = nil
    active_state = false
  end

  if peak_api_available then
    local block_project_sec = math.max(5.0, math.min(60.0, 262000 / scan_rate))
    while cursor < scan_end - 1e-9 do
      guard = guard + 1
      if guard > 100000 then break end
      local block_end = math.min(scan_end, cursor + block_project_sec)
      local n = math.max(1, math.ceil((block_end - cursor) * scan_rate))
      local buf = reaper.new_array(n * 2)
      local retval = GetMediaItemTake_Peaks(take, scan_rate, cursor, 1, n, 0, buf)
      local returned = 0
      if retval and retval > 0 then returned = retval & 0xFFFFF end

      if returned > 0 then
        peak_api_had_data = true
        local limit = math.min(n, returned)
        for i = 1, limit do
          local mx = math.max(math.abs(buf[i] or 0), math.abs(buf[i + n] or 0))
          local proj_t = cursor + (i - 1) / scan_rate
          if not active_state then
            if mx >= attack then
              active_state = true
              active_start = proj_t
            end
          elseif mx >= release then
            -- keep the current active island alive
          else
            close_range(proj_t)
          end
        end
      end
      cursor = block_end
    end
    if active_state then close_range(scan_end) end
  end

  if not peak_api_available or not peak_api_had_data then
    if EXT.debug_mode then
      log("  [ActiveScan] GetMediaItemTake_Peaks unavailable/no data — using AudioAccessor fallback")
    end
    raw_ranges = DetectActiveAudioBounds_AccessorFallback(take, item_pos, item_len, attack, release) or {}
  end

  local merged_active = NormalizeAndMergeRanges(raw_ranges, item_pos, item_len)
  if #merged_active == 0 then
    log(string.format("  [ActiveScan] silent/undetectable take — analysis skipped (threshold %.1f dB)", attack_db))
    return nil
  end

  local padded_ranges = PadActiveRanges(merged_active, item_pos, item_len)
  if #padded_ranges == 0 then return nil end

  local active_start_proj = merged_active[1].start
  local active_end_proj = merged_active[#merged_active].finish
  local analysis_start = padded_ranges[1].start
  local analysis_end = padded_ranges[#padded_ranges].finish
  local active_duration = RangeStats(merged_active)
  local analysis_duration = RangeStats(padded_ranges)
  local internal_gap_duration = math.max(0, (active_end_proj - active_start_proj) - active_duration)
  local gap_compacted = false

  if EXT.compact_internal_silence and #padded_ranges > 1 then
    gap_compacted = internal_gap_duration > 0.5
  end

  log(string.format(
    "  [ActiveScan] item %.3fs → %d active island(s), audio %.3f..%.3f | padded %.3fs across %.3f..%.3f | internal gaps %.3fs%s",
    item_len, #merged_active, active_start_proj, active_end_proj,
    analysis_duration, analysis_start, analysis_end, internal_gap_duration,
    gap_compacted and " | virtual-gap compaction ON" or ""
  ))

  return {
    start = analysis_start, finish = analysis_end,
    active_start = active_start_proj, active_end = active_end_proj,
    active_ratio = math.min(1.0, math.max(0.0, active_duration / math.max(1e-9, item_len))),
    scanned = true, fallback = (not peak_api_had_data),
    active_ranges = merged_active,
    ranges = padded_ranges,
    analysis_duration = analysis_duration,
    active_duration = active_duration,
    internal_gap_duration = internal_gap_duration,
    gap_compacted = gap_compacted,
  }
end

local function BuildPairAnalysisRanges(ref_bounds, dub_bounds, overlap_start, overlap_end)
  local candidates = {}
  for _, b in ipairs({ref_bounds, dub_bounds}) do
    for _, r in ipairs((b and b.ranges) or {}) do
      local a = math.max(overlap_start, r.start)
      local z = math.min(overlap_end, r.finish)
      if z > a then candidates[#candidates + 1] = {start = a, finish = z} end
    end
  end
  table.sort(candidates, function(a,b) return a.start < b.start end)
  local merge_gap = ClampParam(EXT.analysis_merge_gap_ms, 20, 2000, 180) / 1000
  local merged = {}
  for _, r in ipairs(candidates) do
    local last = merged[#merged]
    if last and r.start - last.finish <= merge_gap then
      last.finish = math.max(last.finish, r.finish)
    else
      merged[#merged + 1] = {start = r.start, finish = r.finish}
    end
  end
  if #merged == 0 and overlap_end > overlap_start then
    merged[1] = {start = overlap_start, finish = overlap_end}
  end
  return merged
end

local function CaptureRef_Sync()
  ResetLog()
  local item = GetSelectedMediaItem(0, 0)
  if not item then MB("Select the reference item.", "Error", 0); return false end
  local take = GetActiveTake(item)
  if not take or TakeIsMIDI(take) then MB("The selected reference item has no audio take.", "Error", 0); return false end

  local pos = GetMediaItemInfo_Value(item, 'D_POSITION')
  local len = GetMediaItemInfo_Value(item, 'D_LENGTH')
  local track = GetMediaItem_Track(item)
  local bounds = DetectActiveAudioBounds(take, pos, len)
  if not bounds then
    log("[REF] No analyzable audio found — reference capture aborted.")
    return false
  end

  local analysis_start, analysis_end = bounds.start, bounds.finish
  local analysis_ranges = (EXT.compact_internal_silence and bounds.ranges) or {{start = analysis_start, finish = analysis_end}}
  local separator_sec = EXT.compact_internal_silence and 0.020 or 0.0
  local fp = ReadTrackAudioRanges(track, analysis_ranges, EXT.fp_sr, 1, take, separator_sec)
  local wf = ReadTrackAudioRanges(track, analysis_ranges, EXT.wf_sr, 1, take, separator_sec)
  local env = GetEnvelope(track, take, pos, analysis_start, analysis_end, analysis_ranges)
  if (not fp or #fp < 10) and (not wf or #wf < 10) and #env == 0 then
    log("[REF] No usable analysis data after active-range compaction — reference capture aborted.")
    return false
  end
  Smooth(env, 'rms_b1', EXT.smooth_ms)
  Smooth(env, 'rms_b2', EXT.smooth_ms)
  Smooth(env, 'rms_b3', EXT.smooth_ms)
  Smooth(env, 'rms_b4', EXT.smooth_ms)
  Smooth(env, 'flux_high', EXT.smooth_ms)
  Smooth(env, 'delta_rms', EXT.smooth_ms * 0.5)

  DATA.ref = {
    item=item, take=take, pos=pos, capture_pos=pos, len=len, track=track,
    name=GetTakeName(take), env=env, waveform=wf, fp_audio=fp,
    active_start=bounds.active_start, active_end=bounds.active_end,
    active_ranges=bounds.active_ranges, analysis_ranges=analysis_ranges,
    analysis_start=analysis_start, analysis_end=analysis_end,
    analysis_duration=RangeStats(analysis_ranges),
    internal_gap_duration=bounds.internal_gap_duration or 0,
  }
  DATA.dubs = {}
  DATA.has_aligned = false

  log(string.format("[REF] %s — item %.1fs | audio %.3f..%.3f | analysis %.3f..%.3f",
    DATA.ref.name, len, bounds.active_start, bounds.active_end, analysis_start, analysis_end))
  if len > 120 and bounds.scanned then
    log(string.format("  [INFO] Long item protected: %.1fs item → %.1fs analysed across %d virtual segment(s).", len, RangeStats(analysis_ranges), #analysis_ranges))
  elseif len > 120 then
    log(string.format("  [WARN] Ref item is %.0fs long — active scan fallback kept full item.", len))
  end

  do local n_sm = GetTakeNumStretchMarkers(take) or 0
    if n_sm > 0 then log(string.format("  [WARN] Ref '%s' has %d stretch marker(s): analysis assumes a linear item->source mapping.", DATA.ref.name, n_sm)) end end
  if not fp or #fp < 10 then log("  [WARN] Ref: FP audio empty or too short") end
  if not wf or #wf < 10 then log("  [WARN] Ref: Waveform audio empty or too short") end
  if #env == 0 then log("  [WARN] Ref: Envelope returned 0 frames") end

  return true
end

local function CaptureOneDub_Sync(i)
  local item = GetSelectedMediaItem(0, i)
  if not item or item == DATA.ref.item then return end
  local take = GetActiveTake(item)
  if not take or TakeIsMIDI(take) then return end

  local pos = GetMediaItemInfo_Value(item, 'D_POSITION')
  local len = GetMediaItemInfo_Value(item, 'D_LENGTH')
  local track = GetMediaItem_Track(item)
  local bounds = DetectActiveAudioBounds(take, pos, len)
  if not bounds then
    log(string.format("  [SKIP] Dub '%s': no analyzable audio detected.", GetTakeName(take)))
    return
  end

  local s = math.max(pos, DATA.ref.analysis_start, bounds.start)
  local e = math.min(pos + len, DATA.ref.analysis_end, bounds.finish)
  local overlap = e - s
  if overlap < EXT.min_analysis_overlap_sec then
    log(string.format("  [SKIP] Dub '%s': analyzable overlap %.3fs < minimum %.3fs.",
      GetTakeName(take), math.max(0, overlap), EXT.min_analysis_overlap_sec))
    return
  end

  local pair_ranges
  if EXT.compact_internal_silence then
    pair_ranges = BuildPairAnalysisRanges(DATA.ref, bounds, s, e)
  else
    pair_ranges = {{start = s, finish = e}}
  end
  if not pair_ranges or #pair_ranges == 0 then
    log(string.format("  [SKIP] Dub '%s': no usable analysis ranges after pair clipping.", GetTakeName(take)))
    return
  end
  local pair_duration = RangeStats(pair_ranges)
  if pair_duration < EXT.min_analysis_overlap_sec then
    log(string.format("  [SKIP] Dub '%s': compact analyzable duration %.3fs < minimum %.3fs.",
      GetTakeName(take), pair_duration, EXT.min_analysis_overlap_sec))
    return
  end

  local separator_sec = EXT.compact_internal_silence and 0.020 or 0.0
  local fp_d = ReadTrackAudioRanges(track, pair_ranges, EXT.fp_sr, 1, take, separator_sec)
  local fp_r = ReadTrackAudioRanges(DATA.ref.track, pair_ranges, EXT.fp_sr, 1, DATA.ref.take, separator_sec)
  local wf_d = ReadTrackAudioRanges(track, pair_ranges, EXT.wf_sr, 1, take, separator_sec)
  local wf_r = ReadTrackAudioRanges(DATA.ref.track, pair_ranges, EXT.wf_sr, 1, DATA.ref.take, separator_sec)
  local env_d = GetEnvelope(track, take, pos, s, e, pair_ranges)
  local env_r = GetEnvelope(DATA.ref.track, DATA.ref.take, DATA.ref.pos, s, e, pair_ranges)

  local name = GetTakeName(take)
  local n_sm = GetTakeNumStretchMarkers(take) or 0
  if n_sm > 0 then
    log(string.format("  [WARN] Dub '%s' already has %d stretch marker(s): they will be replaced, and analysis assumes a linear item->source mapping. Clear them before capture for reliable results.", name, n_sm))
  end
  if (not fp_d or #fp_d < 10) and (not wf_d or #wf_d < 10) and #env_d == 0 then
    log(string.format("  [SKIP] Dub '%s': no usable analysis data after compaction.", name))
    return
  end
  if not fp_d or #fp_d < 10 then log(string.format("  [WARN] Dub '%s': FP audio empty or too short", name)) end
  if not wf_d or #wf_d < 10 then log(string.format("  [WARN] Dub '%s': Waveform audio empty or too short", name)) end
  if #env_d == 0 then log(string.format("  [WARN] Dub '%s': Envelope returned 0 frames", name)) end
  if #env_r == 0 then log(string.format("  [WARN] Dub '%s': Ref-side envelope returned 0 frames", name)) end
  if len > 120 and bounds.scanned then
    log(string.format("  [INFO] Dub long item protected: %.1fs item → %.1fs compact analysis across %d segment(s).", len, pair_duration, #pair_ranges))
  elseif len > 120 then
    log(string.format("  [WARN] Dub '%s' is %.0fs long — active scan fallback kept full item.", name, len))
  end
  log(string.format("[DUB] '%s' — overlap %.2fs, compact %.2fs across %d segment(s) (pos=%.3fs len=%.3fs) | active %.3f..%.3f",
    name, overlap, pair_duration, #pair_ranges, pos, len, bounds.active_start, bounds.active_end))

  Smooth(env_d, 'rms_b1', EXT.smooth_ms)
  Smooth(env_d, 'rms_b2', EXT.smooth_ms)
  Smooth(env_d, 'rms_b3', EXT.smooth_ms)
  Smooth(env_d, 'rms_b4', EXT.smooth_ms)
  Smooth(env_d, 'flux_high', EXT.smooth_ms)
  Smooth(env_d, 'delta_rms', EXT.smooth_ms * 0.5)

  Smooth(env_r, 'rms_b1', EXT.smooth_ms)
  Smooth(env_r, 'rms_b2', EXT.smooth_ms)
  Smooth(env_r, 'rms_b3', EXT.smooth_ms)
  Smooth(env_r, 'rms_b4', EXT.smooth_ms)
  Smooth(env_r, 'flux_high', EXT.smooth_ms)
  Smooth(env_r, 'delta_rms', EXT.smooth_ms * 0.5)

  table.insert(DATA.dubs, {
    item=item, take=take, pos=pos, capture_pos=pos, len=len, track=track, name=name,
    env_dub=env_d, env_ref=env_r, wf_dub=wf_d, wf_ref=wf_r, fp_dub=fp_d, fp_ref=fp_r,
    applied_rigid_shift = 0, skip_alignment = false,
    active_start=bounds.active_start, active_end=bounds.active_end,
    active_ranges=bounds.active_ranges, analysis_ranges=pair_ranges,
    analysis_start=s, analysis_end=e, analysis_duration=pair_duration,
    internal_gap_duration=bounds.internal_gap_duration or 0,
  })
end

-------------------------------------------------------------------- 
-- MACHINE D'ÉTAT ASYNCHRONE 
-------------------------------------------------------------------- 
local function ValidateStretchMarkerCandidate(take, item_len, play_rate, take_offset, m_pos, s_pos, min_gap, last_m, last_s, conf, marker_type)
  if not IsFiniteNumber(m_pos) or not IsFiniteNumber(s_pos) then
    return false, "non-finite position"
  end
  if item_len <= 0 or play_rate <= 0 then
    return false, "invalid item/play rate"
  end

  local source = GetMediaItemTake_Source(take)
  local source_len = source and (GetMediaSourceLength(source) or 0) or 0
  local source_lo = take_offset + 1e-7
  local source_hi = take_offset + item_len * play_rate - 1e-7
  if source_len > 0 and IsFiniteNumber(source_len) then
    source_hi = math.min(source_hi, source_len - 1e-7)
  end
  if source_hi <= source_lo then return false, "empty source interval" end

  local item_lo = 1e-7
  local item_hi = item_len - 1e-7
  if m_pos <= item_lo or m_pos >= item_hi then return false, "outside item bounds" end
  if s_pos < source_lo or s_pos > source_hi then return false, "outside source bounds" end

  if last_m > -1e8 then
    local dm = m_pos - last_m
    local ds = s_pos - last_s
    if dm <= 0 then return false, "project position not increasing" end
    if ds <= 0 then return false, "source position not increasing" end
    if dm < min_gap then return false, "minimum marker gap" end

    local r = ds / dm
    local max_r = EXT.max_stretch_ratio
    local min_r = 1 / math.max(1.0, max_r)
    if r < min_r or r > max_r then
      return false, string.format("stretch ratio %.3f outside [%.3f, %.3f]", r, min_r, max_r)
    end
    if (r < 0.85 or r > 1.15) and (conf or 0) < 0.45
        and marker_type ~= "GHOST_START" and marker_type ~= "GHOST_END" then
      return false, string.format("ratio %.3f with low confidence %.2f", r, conf or 0)
    end
    return true, r
  end

  return true, 1.0
end

local function SnapshotStretchMarkers(take)
  local snapshot = { markers = {} }
  if not take or not ValidatePtr2(0, take, "MediaItem_Take*") then return snapshot end
  local n = GetTakeNumStretchMarkers(take) or 0
  for i = 0, n - 1 do
    local ok, pos, src = GetTakeStretchMarker(take, i)
    if ok and ok >= 0 and IsFiniteNumber(pos) and IsFiniteNumber(src) then
      local slope = nil
      if type(GetTakeStretchMarkerSlope) == "function" then
        local sv = GetTakeStretchMarkerSlope(take, i)
        if IsFiniteNumber(sv) then slope = sv end
      end
      snapshot.markers[#snapshot.markers + 1] = {pos = pos, src = src, slope = slope}
    end
  end
  return snapshot
end

local function RestoreStretchMarkers(take, snapshot)
  if not take then return false, "invalid take" end
  snapshot = snapshot or {markers = {}}
  local ok, err = pcall(function()
    ClearStretchMarkers(take)
    for _, m in ipairs(snapshot.markers or {}) do
      local idx = SetTakeStretchMarker(take, -1, m.pos, m.src)
      if not idx or idx < 0 then error(string.format("restore rejected marker %.9fs", m.pos)) end
      if m.slope ~= nil and type(SetTakeStretchMarkerSlope) == "function" then
        SetTakeStretchMarkerSlope(take, idx, m.slope)
      end
    end
  end)
  return ok, ok and nil or err
end

local function VerifyStoredStretchMarker(take, idx, expected_m, expected_s)
  if not idx or idx < 0 then return false, "invalid returned marker index" end
  local ok, actual_m, actual_s = GetTakeStretchMarker(take, idx)
  if not ok or ok < 0 then return false, "marker could not be read back" end
  if not IsFiniteNumber(actual_m) or not IsFiniteNumber(actual_s) then
    return false, "read-back position is non-finite"
  end
  local tol_m = math.max(0.0005, EXT.marker_min_gap_ms / 1000 * 0.05)
  local tol_s = math.max(0.001, tol_m * 4.0)
  if math.abs(actual_m - expected_m) > tol_m or math.abs(actual_s - expected_s) > tol_s then
    return false, string.format("API constrained marker (expected %.9f/%.9f, got %.9f/%.9f)", expected_m, expected_s, actual_m, actual_s)
  end
  return true
end

local function ReplaceStretchMarkersTransactional(take, item_len, play_rate, take_offset, candidates)
  local snapshot = SnapshotStretchMarkers(take)
  if #candidates == 0 then
    return false, 0, 0, 0, snapshot, "no valid marker candidates", nil, nil
  end

  local accepted = {}
  local rejected = 0
  local last_m, last_s = -1e9, -1e9
  for _, fm in ipairs(candidates) do
    local a = fm.a
    local mok = ValidateStretchMarkerCandidate(
      take, item_len, play_rate, take_offset,
      fm.m_pos, fm.s_pos, EXT.marker_min_gap_ms / 1000,
      last_m, last_s, a.conf, a.type
    )
    if mok then
      accepted[#accepted + 1] = fm
      last_m, last_s = fm.m_pos, fm.s_pos
    else
      rejected = rejected + 1
    end
  end

  if #accepted == 0 then
    return false, 0, rejected, 0, snapshot, "all candidates rejected; existing markers preserved", nil, nil
  end

  local placed = 0
  local api_rejected = 0
  local ratio_min, ratio_max = math.huge, -math.huge
  local success = false
  local failure_reason = nil
  local ok_commit, err_commit = pcall(function()
    ClearStretchMarkers(take)
    local previous_m, previous_s = nil, nil
    local last_idx = nil
    for _, fm in ipairs(accepted) do
      local idx = SetTakeStretchMarker(take, -1, fm.m_pos, fm.s_pos)
      if not idx or idx < 0 then
        api_rejected = api_rejected + 1
        error(string.format("SetTakeStretchMarker rejected %.9fs", fm.m_pos))
      end
      local vok, verr = VerifyStoredStretchMarker(take, idx, fm.m_pos, fm.s_pos)
      if not vok then error(verr) end
      if previous_m then
        local dm = fm.m_pos - previous_m
        local ds = fm.s_pos - previous_s
        if dm > 0 then
          local ratio = ds / dm
          ratio_min = math.min(ratio_min, ratio)
          ratio_max = math.max(ratio_max, ratio)
        end
      end
      previous_m, previous_s = fm.m_pos, fm.s_pos
      placed = placed + 1
      last_idx = idx
    end
    success = placed == #accepted
  end)
  if not ok_commit then failure_reason = tostring(err_commit) end

  if not success then
    local restore_ok, restore_err = RestoreStretchMarkers(take, snapshot)
    if not restore_ok then
      failure_reason = (failure_reason or "commit failure") .. "; RESTORE FAILED: " .. tostring(restore_err)
    else
      failure_reason = (failure_reason or "commit failure") .. "; previous markers restored"
    end
    return false, placed, rejected, api_rejected, snapshot, failure_reason, nil, nil
  end

  if ratio_min == math.huge then ratio_min, ratio_max = 1.0, 1.0 end
  return true, placed, rejected, api_rejected, snapshot, nil, ratio_min, ratio_max
end

local function StartCaptureRef() 
  if STATE.mode ~= "idle" then return end 
  STATE.mode = "capturing_ref"; STATE.progress = 0; STATE.progress_text = "Capturing reference..." 
end 

local function StartCaptureDubs() 
  if STATE.mode ~= "idle" or not DATA.ref then return end 
  DATA.dubs = {}; STATE.mode = "capturing_dubs"; STATE.dub_index = -1; STATE.progress = 0; STATE.progress_text = "Capturing dubs..." 
end 
 
local function SnapshotAlignmentTransaction()
  local tx = { items = {} }
  if DATA.ref then tx.reference_item = DATA.ref.item end
  for _, dub in ipairs(DATA.dubs or {}) do
    if dub.item and ValidatePtr2(0, dub.item, "MediaItem*") then
      tx.items[#tx.items + 1] = {
        item = dub.item,
        pos = GetMediaItemInfo_Value(dub.item, 'D_POSITION'),
        take = dub.take,
        markers = SnapshotStretchMarkers(dub.take),
      }
    end
  end
  return tx
end

local function RollbackAlignmentTransaction(reason)
  local tx = DATA.transaction
  if not tx then return true end
  local all_ok = true
  log("  [ROLLBACK] " .. tostring(reason or "alignment failure"))
  PreventUIRefresh(1)
  local ok, err = pcall(function()
    for _, rec in ipairs(tx.items or {}) do
      if rec.item and ValidatePtr2(0, rec.item, "MediaItem*") then
        SetMediaItemInfo_Value(rec.item, 'D_POSITION', rec.pos)
        UpdateItemInProject(rec.item)
      end
      if rec.take and ValidatePtr2(0, rec.take, "MediaItem_Take*") then
        local rok, rerr = RestoreStretchMarkers(rec.take, rec.markers)
        if not rok then
          all_ok = false
          log("  [ROLLBACK ERROR] " .. tostring(rerr))
        end
      end
    end
  end)
  PreventUIRefresh(-1)
  if not ok then
    all_ok = false
    log("  [ROLLBACK ERROR] " .. tostring(err))
  end
  if all_ok then log("  [ROLLBACK] previous item positions and stretch markers restored") end
  return all_ok
end

local function CloseUndoBlock(name)
  if DATA.undo_open then
    DATA.undo_open = false
    Undo_EndBlock2(0, name, -1)
  end
end

local function StartAlign()
  if STATE.mode ~= "idle" or not DATA.ref or #DATA.dubs == 0 then return end

  if not ValidatePtr2(0, DATA.ref.item, "MediaItem*") or not ValidatePtr2(0, DATA.ref.take, "MediaItem_Take*") then
    log("[ERROR] Reference item/take no longer exists — recapture the reference before aligning.")
    STATE.progress_text = "Reference missing — recapture"
    MB("The reference item no longer exists. Please capture the reference again.", "VoxAlign", 0)
    return
  end

  DATA.transaction = SnapshotAlignmentTransaction()
  Undo_BeginBlock2(0)
  DATA.undo_open = true
  log("\n=== ALIGNMENT v15.2.0 (Active Islands + Compact Silence + FastDTW Pyramid + Transactional Markers) ===")

  DATA.ref.pos = DATA.ref.capture_pos

  local ref_max_db = -200
  for _, e in ipairs(DATA.ref.env) do
    local db = val2db(e.rms)
    if db > ref_max_db then ref_max_db = db end
  end
  DATA.ref_max_db = ref_max_db

  for _, dub in ipairs(DATA.dubs) do
    local item_ok = dub.item and ValidatePtr2(0, dub.item, "MediaItem*")
                    and dub.take and ValidatePtr2(0, dub.take, "MediaItem_Take*")
    if not item_ok then
      log(string.format("[SKIP] '%s' no longer exists — alignment skipped.", tostring(dub.name)))
      dub.skip_alignment = true
    elseif (GetMediaItemInfo_Value(dub.item, 'C_LOCK') or 0) ~= 0 then
      log(string.format("[SKIP] '%s' is LOCKED — alignment skipped completely.", dub.name))
      dub.skip_alignment = true
    else
      dub.skip_alignment = false
      dub.pos = dub.capture_pos
      SetMediaItemInfo_Value(dub.item, 'D_POSITION', dub.capture_pos)
    end

    -- La normalisation / segmentation / respirations sont faites ensuite, par
    -- tranches, dans _ProcessAsyncInner (évite un gel de l'UI sur N dubs).
    dub.prep_stage, dub.prep_done = nil, false
    dub.anchors, dub.anchor_i, dub.finalized_markers, dub.marker_ctx = nil, nil, nil, nil
    dub.dtw_state, dub.path, dub.macro_done = nil, nil, nil
    dub.pyramid_done, dub.pyramid_level, dub.guide, dub.guide_4 = nil, nil, nil, nil
    dub.env_ref_16, dub.env_dub_16, dub.env_ref_4, dub.env_dub_4 = nil, nil, nil, nil
    dub.coarse_state, dub.dtw_offset = nil, nil
    dub.applied_rigid_shift = 0
  end
  STATE.mode = "aligning"; STATE.dub_index = 1; STATE.progress = 0; STATE.progress_text = "Aligning..."
end


local function _ProcessAsyncInner() 
  if STATE.mode == "idle" then return end 
  if STATE.mode == "capturing_ref" then 
    local ok = CaptureRef_Sync() 
    STATE.mode = "idle"; STATE.progress = 0 
    if not ok then STATE.progress_text = "Failed to capture ref" end 
    return 
  end 
  if STATE.mode == "capturing_dubs" then 
    local count = CountSelectedMediaItems(0) 
    STATE.dub_index = STATE.dub_index + 1 
    if STATE.dub_index >= count then 
      STATE.mode = "idle"; STATE.progress = 0; STATE.progress_text = string.format("%d dub(s) captured", #DATA.dubs) 
    else 
      CaptureOneDub_Sync(STATE.dub_index) 
      STATE.progress = (STATE.dub_index + 1) / count 
    end 
    return 
  end 
   
  if STATE.mode == "aligning" then 
    local dub = DATA.dubs[STATE.dub_index] 
    if not dub then 
      STATE.mode = "idle"; STATE.progress = 0; STATE.progress_text = "Alignment completed" 
      DATA.has_aligned = true; DATA.transaction = nil; CloseUndoBlock("VoxAlign v15.2.0")
      return 
    end 
     
    if dub.skip_alignment then
      STATE.dub_index = STATE.dub_index + 1 
      STATE.progress = (STATE.dub_index - 1) / #DATA.dubs 
      return
    end

    if not dub.macro_done then 
      log(string.format("\n[%s]", dub.name)) 
      dub.original_pos = dub.pos 
      if EXT.enable_step1 then 
        local global_offset, chosen_score, method, all_results = FindAdaptiveOffset(dub) 
         
        if EXT.rigid_align and math.abs(global_offset) > 0.001 then
          local new_pos = dub.original_pos - global_offset
          SetMediaItemInfo_Value(dub.item, 'D_POSITION', new_pos)
          UpdateItemInProject(dub.item)
          local confirmed_pos = GetMediaItemInfo_Value(dub.item, 'D_POSITION')
          
          dub.applied_rigid_shift = confirmed_pos - dub.original_pos
          dub.pos = confirmed_pos
          dub.dtw_offset = global_offset
          
          local direction = dub.applied_rigid_shift < 0 and "earlier (dub was late)" or "later (dub was early)"
          log(string.format("  → Rigid Align: %+.1fms → item moved %s (new pos=%.4fs)", -dub.applied_rigid_shift * 1000, direction, dub.pos))
        else
          dub.dtw_offset = global_offset
          dub.applied_rigid_shift = 0
          if math.abs(global_offset) <= 0.001 then
            log("  → Rigid Align: offset < 1ms, skipped")
          else
            log(string.format("  → Macro offset=%.1fms (rigid_align disabled)", global_offset * 1000))
          end
        end 
      else 
        dub.dtw_offset = 0 
        dub.applied_rigid_shift = 0
      end 
      dub.macro_done = true
      dub.fp_dub, dub.fp_ref = nil, nil
      dub.wf_dub, dub.wf_ref = nil, nil 
      STATE.progress_text = string.format("DTW: %s (%d/%d)", dub.name, STATE.dub_index, #DATA.dubs) 
      UpdateItemInProject(dub.item) 
      return 
    end 
     
    -- Préparation par étapes (une étape par frame defer) : normalisation,
    -- segmentation en blobs, détection de respirations.
    if EXT.enable_step2 and not dub.prep_done then
      local stage = dub.prep_stage or 1
      if stage == 1 then
        local dub_max_db = -200
        for _, e in ipairs(dub.env_dub) do
          local db = val2db(e.rms)
          if db > dub_max_db then dub_max_db = db end
        end
        local pair_max_db = math.max(DATA.ref_max_db or -200, dub_max_db)
        NormalizeCommon(dub.env_ref, pair_max_db, EXT.gate_db)
        NormalizeCommon(dub.env_dub, pair_max_db, EXT.gate_db)
      elseif stage == 2 then
        SegmentBlobs(dub.env_ref, dub.name .. " (Ref side)")
      elseif stage == 3 then
        SegmentBlobs(dub.env_dub, dub.name .. " (Dub side)")
      elseif stage == 4 then
        MarkBreaths(dub.env_ref, dub.name .. " (Ref side)")
      else
        MarkBreaths(dub.env_dub, dub.name .. " (Dub side)")
        dub.prep_done = true
      end
      dub.prep_stage = stage + 1
      return
    end

    if not EXT.enable_step2 then 
      STATE.dub_index = STATE.dub_index + 1 
      STATE.progress = (STATE.dub_index - 1) / #DATA.dubs 
      return 
    end 
     
    -- Module B: FastDTW Pyramidal Multi-Résolution (3-Niveaux: 1/16 -> 1/4 -> 1/1)
    if EXT.use_fastdtw_pyramid and not dub.pyramid_done then
      if not dub.pyramid_level then dub.pyramid_level = 3 end -- Début au Niveau 3 (1/16)

      if dub.pyramid_level == 3 then
        if not dub.env_ref_16 then
          dub.env_ref_16 = SubsampleEnv(dub.env_ref, 16)
          dub.env_dub_16 = SubsampleEnv(dub.env_dub, 16)
        end
        local hop_16 = EXT.hop_ms * 16
        local path_16, next_st = ComputeLocalDTW_Chunked(
          dub.env_ref_16, dub.env_dub_16, dub.dtw_offset,
          dub.coarse_state, nil, math.floor(EXT.dtw_band_ms * 2 / hop_16), hop_16, false
        )
        dub.coarse_state = next_st
        if path_16 then
          dub.guide_4 = InterpolateCoarsePath(path_16, 4, math.ceil(#dub.env_ref / 4), math.ceil(#dub.env_dub / 4))
          dub.pyramid_level = 2
          dub.coarse_state  = nil
          dub.env_ref_16, dub.env_dub_16 = nil, nil
          collectgarbage("step", 100)
        else
          if dub.coarse_state and dub.coarse_state.N then
            STATE.progress = (STATE.dub_index - 1 + 0.15 * (dub.coarse_state.current_i / dub.coarse_state.N)) / #DATA.dubs
          end
        end
        return

      elseif dub.pyramid_level == 2 then
        if not dub.env_ref_4 then
          dub.env_ref_4 = SubsampleEnv(dub.env_ref, 4)
          dub.env_dub_4 = SubsampleEnv(dub.env_dub, 4)
        end
        local hop_4 = EXT.hop_ms * 4
        local path_4, next_st = ComputeLocalDTW_Chunked(
          dub.env_ref_4, dub.env_dub_4, dub.dtw_offset,
          dub.coarse_state, dub.guide_4, math.floor(EXT.dtw_band_ms / hop_4), hop_4, false
        )
        dub.coarse_state = next_st
        if path_4 then
          dub.guide        = InterpolateCoarsePath(path_4, 4, #dub.env_ref, #dub.env_dub)
          dub.pyramid_done = true
          dub.coarse_state = nil
          dub.env_ref_4, dub.env_dub_4 = nil, nil
          collectgarbage("step", 150)
        else
          if dub.coarse_state and dub.coarse_state.N then
            STATE.progress = (STATE.dub_index - 1 + 0.15 + 0.20 * (dub.coarse_state.current_i / dub.coarse_state.N)) / #DATA.dubs
          end
        end
        return
      end
    end

    -- Finalisation des markers, par tranches de temps (micro-align + zero-crossing
    -- ouvrent des accessors audio : trop lourd pour une seule frame defer).
    if dub.anchors then
      local anchors = dub.anchors
      local mc = dub.marker_ctx
      local t_slice = time_precise()
      local micro_scale = EXT.micro_window_ms / 150

      while dub.anchor_i <= #anchors do
        local a = anchors[dub.anchor_i]
        local is_ghost = (a.type == "GHOST_START" or a.type == "GHOST_END")
        local target_proj           = a.ref_t
        local current_physical_proj = CapturedDubTimeToCurrentProjectTime(dub, a.dub_t)

        if EXT.use_micro_align and not is_ghost then
          local micro_win = EXT.micro_window_ms / 1000
          if a.type == "ONSET" then micro_win = 0.040 * micro_scale
          elseif a.type == "START" then micro_win = 0.060 * micro_scale
          elseif a.type == "END"   then micro_win = 0.080 * micro_scale end

          local lag_sec = MicroAlignAnchor(DATA.ref.track, dub.track, target_proj,
            current_physical_proj, micro_win, EXT.micro_sr, DATA.ref.take, dub.take)
          target_proj = target_proj - lag_sec
        end

        local final_proj = current_physical_proj + (target_proj - current_physical_proj) * EXT.align_strength
        local offset_sec = EXT.marker_offset_ms / 1000
        local m_pos = (final_proj - dub.pos) + offset_sec
        local s_pos = mc.take_offset + (current_physical_proj - dub.pos) * mc.play_rate + (offset_sec * mc.play_rate)

        if EXT.use_zero_crossing then
          local new_s_pos = FindNearestZeroCrossing(dub.take, s_pos, EXT.zx_window_ms)
          m_pos = m_pos + ((new_s_pos - s_pos) / mc.play_rate)
          s_pos = new_s_pos
        end
        dub.finalized_markers[#dub.finalized_markers + 1] = {m_pos = m_pos, s_pos = s_pos, a = a}
        dub.anchor_i = dub.anchor_i + 1
        if time_precise() - t_slice > DTW_CHUNK_TIME_BUDGET_SEC then break end
      end

      if dub.anchor_i <= #anchors then
        STATE.progress = (STATE.dub_index - 1 + 0.95 + 0.05 * ((dub.anchor_i - 1) / #anchors)) / #DATA.dubs
        STATE.progress_text = string.format("Markers: %s (%d/%d)", dub.name, dub.anchor_i - 1, #anchors)
        return
      end

      local finalized_markers = dub.finalized_markers
      table.sort(finalized_markers, function(a, b) return a.m_pos < b.m_pos end)

      local ok_replace, placed, rejected, failed_api, marker_snapshot, replace_error, tx_ratio_min, tx_ratio_max = ReplaceStretchMarkersTransactional(
        dub.take, dub.len, mc.play_rate, mc.take_offset, finalized_markers
      )
      local ratio_min, ratio_max = tx_ratio_min or 1.0, tx_ratio_max or 1.0

      log(string.format("  → %d stretch markers placed | rejected=%d | API rejected=%d | ratio min=%.3f max=%.3f",
        placed, rejected, failed_api, ratio_min, ratio_max))
      if not ok_replace then
        log("  [MARKER TRANSACTION] " .. tostring(replace_error or "failed; previous marker state preserved/restored"))
      end
      log(string.format("  [Done] '%s' — macro=%+.1fms | markers=%d | ratio=[%.3f, %.3f]",
        dub.name, dub.applied_rigid_shift * 1000, placed, ratio_min, ratio_max))

      dub.anchors, dub.finalized_markers, dub.marker_ctx, dub.anchor_i = nil, nil, nil, nil
      UpdateItemInProject(dub.item)
      STATE.dub_index = STATE.dub_index + 1
      STATE.progress = (STATE.dub_index - 1) / #DATA.dubs
      return
    end

    local path, next_state = ComputeLocalDTW_Chunked(
      dub.env_ref, dub.env_dub, dub.dtw_offset,
      dub.dtw_state,
      dub.guide,
      math.floor(EXT.dtw_band_ms * 0.5 / EXT.hop_ms),
      nil,
      true
    )
    dub.dtw_state = next_state

    if path then
      dub.path = path
      local anchors = ExtractAnchors(path, dub.env_ref, dub.env_dub, dub)
      log(string.format("  DTW: path=%d | Smart Anchors=%d (Selected by confidence > %.2f)", #path, #anchors, EXT.anchor_min_conf))

      local play_rate = GetMediaItemTakeInfo_Value(dub.take, 'D_PLAYRATE')
      local take_offset = GetMediaItemTakeInfo_Value(dub.take, 'D_STARTOFFS')
      if not play_rate or play_rate <= 0 then play_rate = 1.0 end
      if not take_offset or not IsFiniteNumber(take_offset) then take_offset = 0.0 end

      dub.marker_ctx = {play_rate = play_rate, take_offset = take_offset}
      dub.anchors, dub.anchor_i, dub.finalized_markers = anchors, 1, {}
    else
      if dub.dtw_state and dub.dtw_state.N then
        STATE.progress = (STATE.dub_index - 1 + 0.35 + (dub.dtw_state.current_i / dub.dtw_state.N) * 0.60) / #DATA.dubs
      end
    end
    return
  end
end

local function ProcessAsync()
  local ok, err = pcall(_ProcessAsyncInner)
  if not ok then
    log("  [ERROR] ProcessAsync failed: " .. tostring(err))
    if STATE.mode ~= "idle" then
      RollbackAlignmentTransaction(err)
      DATA.transaction = nil
      CloseUndoBlock("VoxAlign (erreur)")
    end
    STATE.mode = "idle"
    STATE.progress = 0
    STATE.progress_text = "Error — see diagnostics log"
  end
end

-------------------------------------------------------------------- 
-- PRESETS SYSTEM 
--------------------------------------------------------------------
local PRESETS = {
  {
    name = "2 Mics / Same Take",
    desc = "Same performer, 2 mics. Fixed offset, no stretch.",
    settings = {
      enable_step1        = true,
      rigid_align         = true,
      enable_step2        = false,
      use_micro_align     = false,
      use_segmentation    = false,
      enable_breath_protect = false,
      dtw_band_ms         = 80,
      drift_tolerance_sec = 0.060,
      dtw_slope_penalty   = 0.12,
      align_strength      = 1.0,
      max_stretch_ratio   = 1.2,
      anchor_min_conf     = 0.30,
      blob_gap_ms         = 60,
      zx_window_ms        = 2,
    }
  },
  {
    name = "Double Tracking",
    desc = "Same singer, slight rhythmic variations with breath protection.",
    settings = {
      enable_step1        = true,
      rigid_align         = true,
      enable_step2        = true,
      use_fastdtw_pyramid = true,
      use_micro_align     = true,
      use_segmentation    = true,
      enable_breath_protect = true,
      dtw_band_ms         = 150,
      drift_tolerance_sec = 0.120,
      dtw_slope_penalty   = 0.10,
      align_strength      = 0.90,
      max_stretch_ratio   = 1.5,
      anchor_min_conf     = 0.25,
      blob_gap_ms         = 80,
      zx_window_ms        = 5,
    }
  },
  {
    name = "Backing Vocals",
    desc = "Different singer(s), free rhythmic interpretation & breath protection.",
    settings = {
      enable_step1        = true,
      rigid_align         = true,
      enable_step2        = true,
      use_fastdtw_pyramid = true,
      use_micro_align     = true,
      use_segmentation    = true,
      enable_breath_protect = true,
      dtw_band_ms         = 180,
      drift_tolerance_sec = 0.150,
      dtw_slope_penalty   = 0.08,
      align_strength      = 0.80,
      max_stretch_ratio   = 1.6,
      anchor_min_conf     = 0.21,
      blob_gap_ms         = 120,
      zx_window_ms        = 5,
    }
  },
  {
    name = "Harmonic Instrument",
    desc = "Guitar, piano, strings. Soft attacks, long sustain.",
    settings = {
      enable_step1        = true,
      rigid_align         = true,
      enable_step2        = true,
      use_fastdtw_pyramid = true,
      use_micro_align     = true,
      use_segmentation    = true,
      enable_breath_protect = false,
      dtw_band_ms         = 200,
      drift_tolerance_sec = 0.200,
      dtw_slope_penalty   = 0.06,
      align_strength      = 0.80,
      max_stretch_ratio   = 1.8,
      anchor_min_conf     = 0.20,
      blob_gap_ms         = 150,
      zx_window_ms        = 8,
      dtw_feature_weight  = 0.45,
      dtw_delta_weight    = 0.25,
    }
  },
  {
    name = "Percussive / Bass",
    desc = "Bass, drums, plucked. Sharp transients, minimal sustain.",
    settings = {
      enable_step1        = true,
      rigid_align         = true,
      enable_step2        = true,
      use_fastdtw_pyramid = true,
      use_micro_align     = true,
      use_segmentation    = false,
      enable_breath_protect = false,
      dtw_band_ms         = 120,
      drift_tolerance_sec = 0.100,
      dtw_slope_penalty   = 0.04,
      align_strength      = 0.95,
      max_stretch_ratio   = 1.6,
      anchor_min_conf     = 0.15,
      blob_gap_ms         = 40,
      zx_window_ms        = 3,
      onset_thr_db        = 3.0,
      dtw_feature_weight  = 0.70,
      dtw_delta_weight    = 0.20,
    }
  },
}

-------------------------------------------------------------------- 
-- INTERFACE UTILISATEUR 
-------------------------------------------------------------------- 
local function DrawUI() 
  ProcessAsync() 
   
  local visible, open = ImGui.Begin(ctx, 'VoxAlign v15.2.0', true,
ImGui.WindowFlags_NoResize | ImGui.WindowFlags_AlwaysAutoResize) 
  if visible then 
    local is_busy = STATE.mode ~= "idle" 
    if is_busy then open = true end
     
    ImGui.SeparatorText(ctx, "Preset")
    ImGui.BeginDisabled(ctx, is_busy)

    if not EXT._preset_idx then EXT._preset_idx = 0 end
    local preview = EXT._preset_idx == 0 and "— Custom —" or PRESETS[EXT._preset_idx].name
    if ImGui.BeginCombo(ctx, "##preset", preview) then
      if ImGui.Selectable(ctx, "— Custom —", EXT._preset_idx == 0) then
        EXT._preset_idx = 0
      end
      for i, p in ipairs(PRESETS) do
        if ImGui.Selectable(ctx, p.name, EXT._preset_idx == i) then
          EXT._preset_idx = i
          for k, v in pairs(p.settings) do EXT[k] = v end
          DATA.has_aligned = false; MarkSettingsDirty()
        end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, p.desc) end
      end
      ImGui.EndCombo(ctx)
    end

    if EXT._preset_idx > 0 then
      ImGui.TextColored(ctx, 0xAAAAAAFF, PRESETS[EXT._preset_idx].desc)
    end

    ImGui.EndDisabled(ctx)
    ImGui.Spacing(ctx)

    ImGui.SeparatorText(ctx, "Files") 
    if DATA.ref then  
      ImGui.TextColored(ctx, 0x55FF55FF, "✓ Ref : " .. DATA.ref.name)  
    else  
      ImGui.TextColored(ctx, 0xFF5555FF, "✗ No reference")  
    end 
    ImGui.BeginDisabled(ctx, is_busy) 
    if ImGui.Button(ctx, "Capture REFERENCE", 460) then StartCaptureRef() end 
    ImGui.EndDisabled(ctx) 
    ImGui.Spacing(ctx) 
     
    if #DATA.dubs > 0 then 
      ImGui.TextColored(ctx, 0x55FF55FF, "✓ " .. #DATA.dubs .. " dub(s)") 
    else  
      ImGui.TextColored(ctx, 0xFF5555FF, "✗ No dubs")  
    end 
    ImGui.BeginDisabled(ctx, is_busy or not DATA.ref) 
    if ImGui.Button(ctx, "Capture DUBS", 460) then StartCaptureDubs() end 
    ImGui.EndDisabled(ctx) 
 
    if is_busy then 
      ImGui.Spacing(ctx) 
      ImGui.ProgressBar(ctx, STATE.progress, 460, 20, STATE.progress_text) 
      ImGui.Spacing(ctx) 
    end 
 
    ImGui.SeparatorText(ctx, "Step 1 — Macro-alignment") 
    ImGui.BeginDisabled(ctx, is_busy) 
    local c_s1, v_s1 = ImGui.Checkbox(ctx, "Enable Macro-alignment", EXT.enable_step1) 
    if c_s1 then EXT.enable_step1 = v_s1; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
    ImGui.BeginDisabled(ctx, not EXT.enable_step1) 
    local c_rigid, v_rigid = ImGui.Checkbox(ctx, "Move item physically (Rigid Align)", EXT.rigid_align) 
    if c_rigid then EXT.rigid_align = v_rigid; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
    ImGui.EndDisabled(ctx) 
    ImGui.EndDisabled(ctx) 
 
    if ImGui.CollapsingHeader(ctx, "Step 1.5 — Segmentation & Breath Protection") then 
    ImGui.BeginDisabled(ctx, is_busy) 
    local c_seg, v_seg = ImGui.Checkbox(ctx, "Enable vocal Blobs restriction", EXT.use_segmentation) 
    if c_seg then EXT.use_segmentation = v_seg; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
     
    ImGui.BeginDisabled(ctx, not EXT.use_segmentation) 
    local czcr, vzcr = ImGui.SliderDouble(ctx, "Max ZCR (Tonality)", EXT.zcr_threshold, 0.05, 0.40, "%.3f") 
    if czcr then EXT.zcr_threshold = vzcr; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
     
    local ctrans, vtrans = ImGui.SliderDouble(ctx, "Consonants Sensitivity (Flux)", EXT.transient_threshold, 0.05, 0.50, "%.2f") 
    if ctrans then EXT.transient_threshold = vtrans; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
     
    local cgap, vgap = ImGui.SliderInt(ctx, "Gap Bridging (ms)", EXT.blob_gap_ms, 20, 200) 
    if cgap then EXT.blob_gap_ms = vgap; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
    ImGui.EndDisabled(ctx) 

    local c_brth, v_brth = ImGui.Checkbox(ctx, "Enable Breath Protection (Module C)", EXT.enable_breath_protect)
    if c_brth then EXT.enable_breath_protect = v_brth; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Prevents time-stretching on breath/inhalation noise.") end

    ImGui.EndDisabled(ctx) 

    end -- Step 1.5

    if ImGui.CollapsingHeader(ctx, "V15 — Robust analysis bounds") then
    ImGui.BeginDisabled(ctx, is_busy)
    local c_trim, v_trim = ImGui.Checkbox(ctx, "Auto-detect audio and ignore leading/trailing silence", EXT.auto_trim_analysis)
    if c_trim then EXT.auto_trim_analysis = v_trim; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Keeps the original item intact. VoxAlign only analyses the active-audio region plus padding; internal musical silence is preserved.") end

    ImGui.BeginDisabled(ctx, not EXT.auto_trim_analysis)
    local c_thr, v_thr = ImGui.SliderDouble(ctx, "Audio activity threshold (dB)", EXT.analysis_threshold_db, -90.0, -25.0, "%.1f dB")
    if c_thr then EXT.analysis_threshold_db = v_thr; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end
    local c_pad, v_pad = ImGui.SliderInt(ctx, "Analysis safety padding (ms)", EXT.analysis_padding_ms, 0, 1000)
    if c_pad then EXT.analysis_padding_ms = v_pad; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end

    local c_compact, v_compact = ImGui.Checkbox(ctx, "Compact long internal silence (virtual)", EXT.compact_internal_silence)
    if c_compact then EXT.compact_internal_silence = v_compact; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Does not split or edit the REAPER item. Active islands are analysed as separate virtual segments; project timestamps are preserved for anchors/markers.") end

    local c_merge, v_merge = ImGui.SliderInt(ctx, "Merge nearby active islands (ms)", EXT.analysis_merge_gap_ms, 20, 500)
    if c_merge then EXT.analysis_merge_gap_ms = v_merge; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end
    ImGui.EndDisabled(ctx)
    ImGui.EndDisabled(ctx)
 
    end -- V15 bounds

    ImGui.SeparatorText(ctx, "Step 2 — Micro-alignment & FastDTW Pyramid") 
    ImGui.BeginDisabled(ctx, is_busy) 
    local c_s2, v_s2 = ImGui.Checkbox(ctx, "Enable Stretch Markers placement", EXT.enable_step2) 
    if c_s2 then EXT.enable_step2 = v_s2; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
     
    ImGui.BeginDisabled(ctx, not EXT.enable_step2) 
    local c_pyr, v_pyr = ImGui.Checkbox(ctx, "FastDTW Pyramidal Multi-Res (Module B)", EXT.use_fastdtw_pyramid)
    if c_pyr then EXT.use_fastdtw_pyramid = v_pyr; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "3-level pyramid (1/16 -> 1/4 -> 1/1) for ultra-fast and precise alignment.") end

    local c_conf, v_conf = ImGui.SliderDouble(ctx, "Minimum local confidence", EXT.anchor_min_conf, 0.0, 0.50, "%.2f") 
    if c_conf then EXT.anchor_min_conf = v_conf; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Filters out unreliable false markers during Time-Warping.") end 

    local c_drift, v_drift = ImGui.SliderDouble(ctx, "Max Drift Tolerance (sec)", EXT.drift_tolerance_sec, 0.05, 0.50, "%.3f")
    if c_drift then EXT.drift_tolerance_sec = v_drift; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end
 
    local c_slope, v_slope = ImGui.SliderDouble(ctx, "DTW Anti-staircase (Slope Penalty)", EXT.dtw_slope_penalty, 0.0, 0.15, "%.2f") 
    if c_slope then EXT.dtw_slope_penalty = v_slope; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Forces DTW to remain natural and fluid rather than warping brutally.") end 
     
    local c6, v6 = ImGui.SliderDouble(ctx, "Max stretch ratio", EXT.max_stretch_ratio, 1.2, 5.0, "%.1f x") 
    if c6 then EXT.max_stretch_ratio = v6; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
     
    local c_strength, v_strength = ImGui.SliderDouble(ctx, "Alignment strength", EXT.align_strength, 0.1, 1.0, "%.2f") 
    if c_strength then EXT.align_strength = v_strength; EXT._preset_idx = 0; MarkSettingsDirty() end
     
    local c12, v12 = ImGui.Checkbox(ctx, "Dynamic micro-alignment", EXT.use_micro_align) 
    if c12 then EXT.use_micro_align = v12; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
    ImGui.BeginDisabled(ctx, not EXT.use_micro_align)
    local c_mw, v_mw = ImGui.SliderInt(ctx, "Micro-align window (ms)", EXT.micro_window_ms, 20, 500)
    if c_mw then EXT.micro_window_ms = v_mw; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Base search window for local micro-alignment. Onset/start/end anchors use 27% / 40% / 53% of it (150 ms = 40/60/80 ms).") end
    ImGui.EndDisabled(ctx)
     
    local c8, v8 = ImGui.Checkbox(ctx, "Force to zero points (Zero Crossing)", EXT.use_zero_crossing) 
    if c8 then EXT.use_zero_crossing = v8; DATA.has_aligned = false; EXT._preset_idx = 0; MarkSettingsDirty() end 
    ImGui.EndDisabled(ctx) 
    ImGui.EndDisabled(ctx) 
 
    ImGui.Spacing(ctx) 
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2A7E2AFF) 
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x3A9E3AFF) 
    local active = (DATA.ref and #DATA.dubs > 0 and not is_busy) 
    if not active then ImGui.BeginDisabled(ctx) end 
    if ImGui.Button(ctx, "ALIGN", 460, 40) then StartAlign() end 
    if not active then ImGui.EndDisabled(ctx) end 
    ImGui.PopStyleColor(ctx, 2) 
 
    ImGui.BeginDisabled(ctx, is_busy) 
    if ImGui.Button(ctx, "Delete stretch markers", 460, 25) then 
      Undo_BeginBlock2(0)
      local n_cleared, n_locked, n_failed = 0, 0, 0
      for _, d in ipairs(DATA.dubs) do
        if not (d.item and ValidatePtr2(0, d.item, "MediaItem*") and d.take and ValidatePtr2(0, d.take, "MediaItem_Take*")) then
          n_failed = n_failed + 1
        elseif (GetMediaItemInfo_Value(d.item, 'C_LOCK') or 0) ~= 0 then
          n_locked = n_locked + 1
        else
          local ok_clear, err_clear = pcall(function()
            ClearStretchMarkers(d.take); UpdateItemInProject(d.item)
          end)
          if ok_clear then
            n_cleared = n_cleared + 1
          else
            n_failed = n_failed + 1
            log("  [ERROR] Delete stretch markers failed: " .. tostring(err_clear))
          end
        end
      end
      Undo_EndBlock2(0, "Clear markers", -1)
      log(string.format("[Clear] markers removed on %d item(s) | locked skipped=%d | failed/missing=%d", n_cleared, n_locked, n_failed))
      DATA.has_aligned = false
    end 
    ImGui.EndDisabled(ctx) 
 
    if ImGui.CollapsingHeader(ctx, "Diagnostics") then
      FlushLog()
      ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x101010FF) 
      local child_visible = ImGui.BeginChild(ctx, "log", 460, 200)
      if child_visible then
        ImGui.TextWrapped(ctx, DATA.log ~= "" and DATA.log or "(Waiting for alignment)") 
        local scroll_y = ImGui.GetScrollY(ctx)
        local scroll_max_y = ImGui.GetScrollMaxY(ctx)
        if scroll_max_y <= 0 or scroll_y >= scroll_max_y - 5.0 then
          ImGui.SetScrollHereY(ctx, 1.0)
        end
      end
      ImGui.EndChild(ctx)
      ImGui.PopStyleColor(ctx) 
    end

    if STATE.mode == "idle" and _settings_dirty then SaveSettings(); _settings_dirty = false end
    ImGui.End(ctx) 
  end 

  if open then reaper.defer(DrawUI) end 
end 

reaper.atexit(function()
  if STATE.mode ~= "idle" then
    pcall(RollbackAlignmentTransaction, "script stopped while alignment was running")
    DATA.transaction = nil
    pcall(CloseUndoBlock, "VoxAlign (interrompu)")
  end
end)

reaper.defer(DrawUI)