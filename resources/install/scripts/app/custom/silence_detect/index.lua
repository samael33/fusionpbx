-- Script to accept 2 vars
-- argv2 - Transfer to if silence detected
-- argv3 - max detect silence in seconds
-- argv4 - sample file length. Best if would be length of ringback-tone

require "app.custom.silence_detect.resources.functions.silence_detect_functions"

if session:ready() then

    local transfer_on_silence = argv[2] or nil
    
    if transfer_on_silence then

        local max_detect_length = tonumber(argv[3]) or 10
        local sample_file_length = tonumber(argv[4]) or 1

        local record_append = session:getVariable('RECORD_APPEND') or nil
        local record_read_only = session:getVariable('RECORD_READ_ONLY') or nil
        local record_stereo = session:getVariable('RECORD_STEREO') or nil

        local loop_count = math.floor(max_detect_length / sample_file_length)

        local tmp_file_name = session:getVariable('call_uuid') or "tmp_file"
        local tmp_dir = '/tmp/'

        tmp_file_name = tmp_dir .. tmp_file_name .. '_sil_det.wav'

        --session:setVariable('RECORD_READ_ONLY', 'true')
        session:setVariable('RECORD_APPEND', 'false')
        session:setVariable('RECORD_STEREO', 'true')
        -- Answer the call
        session:answer()

        for i = 1, loop_count do
            session:execute("record_session", tmp_file_name)
            session:execute("playback", 'tone_stream://$${ringback}')
            session:execute("stop_record_session", tmp_file_name)
            silence_detect_in_file(tmp_file_name)
        end

        -- Restore variables
        session:execute("unset", "RECORD_READ_ONLY")
        if record_append then
            session:setVariable('RECORD_APPEND', record_append)
        end
        if record_read_only then
            session:setVariable('RECORD_READ_ONLY', record_read_only)
        end
        if record_stereo then
            session:setVariable('RECORD_STEREO', record_stereo)
        end
    end
end