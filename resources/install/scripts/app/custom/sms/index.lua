--	sms.lua
--	Part of FusionPBX
--	Copyright (C) 2010-2017 Mark J Crane <markjcrane@fusionpbx.com>
--	All rights reserved.
--
--	Redistribution and use in source and binary forms, with or without
--	modification, are permitted provided that the following conditions are met:
--
--	1. Redistributions of source code must retain the above copyright notice,
--	   this list of conditions and the following disclaimer.
--
--	2. Redistributions in binary form must reproduce the above copyright
--	   notice, this list of conditions and the following disclaimer in the
--	   documentation and/or other materials provided with the distribution.
--
--	THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
--	INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
--	AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
--	AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
--	OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
--	SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
--	INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
--	CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
--	ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
--	POSSIBILITY OF SUCH DAMAGE.

opthelp = [[
 -s, --source=OPTARG	Source of the message
 -d, --debug			Debug flag			
]]


function save_sms_to_database(params)
	sql = "INSERT INTO v_sms_messages "
	sql = sql .."( "
	sql = sql .."domain_uuid, "
	sql = sql .."sms_message_uuid, "
	sql = sql .."sms_message_timestamp, "
	sql = sql .."sms_message_from, "
	sql = sql .."sms_message_to, "
	sql = sql .."sms_message_direction, "
	sql = sql .."sms_message_text, "
	sql = sql .."sms_message_status "
	sql = sql ..") "
	sql = sql .."VALUES ( "
	sql = sql ..":domain_uuid, "
	sql = sql ..":sms_message_uuid, "
	sql = sql .."now(), "
	sql = sql ..":sms_message_from, "
	sql = sql ..":sms_message_to, "
	sql = sql ..":sms_message_direction, "
	sql = sql ..":sms_message_text, "
	sql = sql ..":sms_message_status "
	sql = sql ..")"

	--run the query
	db:query(sql, params);
end


local log = require "resources.functions.log".sms

local Settings = require "resources.functions.lazy_settings"
local Database = require "resources.functions.database"
require "resources.functions.trim";

api = freeswitch.API();

local db = dbh or Database.new('system')
--exits the script if we didn't connect properly
assert(db:connected());

opts, args, err = require('app.custom.functions.optargs').from_opthelp(opthelp, argv)

if opts == nil then
    log.error("Options are not parsable " .. err)
    do return end
end

local sms_source = opts.s or 'internal'

if sms_source == 'internal' then
	if opts.d then log.info("Message source is internal. Saving to database") end

	uuid               = message:getHeader("Core-UUID")
	from_user          = message:getHeader("from_user")
	from_domain        = message:getHeader("from_host")
	to_user            = message:getHeader("to_user")
	to_domain          = message:getHeader("to_host") or from_domain
	content_type       = message:getHeader("type")
	sms_message_text   = message:getBody()

	--Clean body up for Groundwire send
	local sms_message_text_raw = sms_message_text
	local _, sms_temp_end = string.find(sms_message_text_raw, 'Content%-length:')
	if sms_temp_end == nil then
		sms_message_text = sms_message_text_raw
	else
		_, sms_temp_end = string.find(sms_message_text_raw, '\r\n\r\n', sms_temp_end)
		if sms_temp_end == nil then
			sms_message_text = sms_message_text_raw
		else
			sms_message_text = string.sub(sms_message_text_raw, sms_temp_end + 1)
		end
	end

	sms_message_text = sms_message_text:gsub('%"','')
	sms_type      	 = 'sms'

	-- Getting from/to user data
	local domain_uuid
	if (from_user and from_domain) then
		sms_message_from   = from_user .. '@' .. from_domain
		-- Getting domain_uuid
		cmd = "user_data ".. from_user .. "@" .. from_domain .. " var domain_uuid"
		domain_uuid = trim(api:executeString(cmd))
		-- Getting from_user_exists
		cmd = "user_exists id ".. from_user .." "..from_domain
		from_user_exists = api:executeString(cmd)
	else 
		log.error("From user or from domain is not existed. Cannot prcess this message as internal")
		do return end
	end

	if opts.d then log.notice("From user exists: " .. from_user_exists) end

	if (to_user and to_domain) then
		sms_message_to     = to_user .. '@' .. to_domain

		cmd = "user_exists id ".. to_user .." "..to_domain
		to_user_exists = api:executeString(cmd)
	else
		to_user_exists = 'false'
	end
	-- End getting from/to user data
	
	if (from_user_exists == 'false') then
		log.error("From user is not exists. Cannot process this request")
		do return end
	end

	if not domain_uuid then
		log.error("Please make sure " .. domain_name .. " is existed on the system")
		do return end
	end

	-- Get settings
	local settings = Settings.new(db, from_domain, domain_uuid)

	if (to_user_exists == 'true') then

		--set the parameters for database save
		local params= {
			domain_uuid = domain_uuid,
			sms_message_uuid = api:executeString("create_uuid"),
			sms_message_from = sms_message_from,
			sms_message_to = sms_message_to,
			sms_message_direction = 'send',
			sms_message_status = 'Sent. Local',
			sms_message_text = sms_message_text,
		}

		save_sms_to_database(params)

		do return end
	end

	-- SMS to external

	if not to_user then
		local params= {
			domain_uuid = domain_uuid,
			sms_message_uuid = api:executeString("create_uuid"),
			sms_message_from = sms_message_from,
			sms_message_to = "NA",
			sms_message_direction = 'send',
			sms_message_status = 'Error. No TO user specified',
			sms_message_text = sms_message_text,
		}
		save_sms_to_database(params)

		log.error('To user is empty. Discarding sent')
		do return end
	end

	-- Get routing rules for this message type.
	sql =        "SELECT sms_routing_source, "
	sql = sql .. "sms_routing_destination, "
	sql = sql .. "sms_routing_target_details"
	sql = sql .. " FROM v_sms_routing WHERE"
	sql = sql .. " domain_uuid = :domain_uuid"
	sql = sql .. " AND sms_routing_target_type = 'carrier'"
	sql = sql .. " AND sms_routing_enabled = 'true'"

	local params = {
		domain_uuid = domain_uuid
	}

	local routing_patterns = {}
	db:query(sql, params, function(row)
		table.insert(routing_patterns, row)
	end);
	
	local sms_carrier

	if (len(routing_patterns) == 0) then

		local params= {
			domain_uuid = domain_uuid,
			sms_message_uuid = api:executeString("create_uuid"),
			sms_message_from = sms_message_from,
			sms_message_to = to_user,
			sms_message_direction = 'send',
			sms_message_status = 'Error. No routing patterns',
			sms_message_text = sms_message_text,
		}
		save_sms_to_database(params)

		log.notice("External routing table is empty. Exiting.")

		do return end
	end

	for _, routing_pattern in pairs(routing_patterns) do
		sms_routing_source = routing_pattern['sms_routing_source']
		sms_routing_destination = routing_pattern['sms_routing_destination']

		if (from_user:find(sms_routing_source) and to_user:find(sms_routing_destination)) then
			sms_carrier = routing_pattern['sms_routing_target_details']
			if opts.d then log.notice("Using " .. sms_carrier .. " for this SMS") end
			break
		end
	end

	if (not sms_carrier) then

		local params= {
			domain_uuid = domain_uuid,
			sms_message_uuid = api:executeString("create_uuid"),
			sms_message_from = sms_message_from,
			sms_message_to = to_user,
			sms_message_direction = 'send',
			sms_message_status = 'Error. No carrier found',
			sms_message_text = sms_message_text,
		}
		save_sms_to_database(params)

		log.warning("Cannot find carrier for this SMS: From:" .. sms_message_from .. "  To: " .. sms_message_to)
		do return end
	end

	local sms_request_type = settings:get('sms', sms_carrier .. '_request_type', 'text')
	local sms_carrier_url = settings:get('sms', sms_carrier .. "_url", 'text')
	local sms_carrier_user = settings:get('sms', sms_carrier .. "_user", 'text')
	local sms_carrier_password = settings:get("sms", sms_carrier .. "_password", 'text')
	local sms_carrier_body_type = settings:get("sms", sms_carrier .. "_body", "text")
	local sms_carrier_content_type = settings:get("sms", sms_carrier .. "_content_type", "text") or "application/json"
	local sms_carrier_method =  settings:get("sms", sms_carrier .. "_method", "text") or 'post'

	--get the sip user outbound_caller_id
	cmd = "user_data ".. from_user .."@"..from_host.." var outbound_caller_id_number"
	caller_id_from = trim(api:executeString(cmd))


else 
	log.warning("[sms] Source " .. sms_source .. " is not yet implemented")
end
--[=====[

--define the functions
local Settings = require "resources.functions.lazy_settings"
local Database = require "resources.functions.database"

-- get the configuration variables from the DB
local db = dbh or Database.new('system')
local settings = Settings.new(db, domain_name, domain_uuid)

--set the api
api = freeswitch.API();

--define the urlencode function
local function urlencode(s)
	s = string.gsub(s, "([^%w])",function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	return s
end

--get the argv values
	script_name = argv[0];
	direction = argv[2];
	
	if (debug["info"]) then
		freeswitch.consoleLog("notice", "[sms] DIRECTION: " .. direction .. "\n");
		freeswitch.consoleLog("info", "chat console\n");
	end
	
	if direction == "inbound" then
		to = argv[3];
		from = argv[4];
		body = argv[5];
		domain_name = string.match(to,'%@+(.+)');
		extension = string.match(to,'%d+');

		if (debug["info"]) then
			freeswitch.consoleLog("notice", "[sms] DIRECTION: " .. direction .. "\n");
			freeswitch.consoleLog("notice", "[sms] TO: " .. to .. "\n");
			freeswitch.consoleLog("notice", "[sms] Extension: " .. extension .. "\n");
			freeswitch.consoleLog("notice", "[sms] FROM: " .. from .. "\n");
			freeswitch.consoleLog("notice", "[sms] BODY: " .. body .. "\n");
			freeswitch.consoleLog("notice", "[sms] DOMAIN_NAME: " .. domain_name .. "\n");
		end

		local event = freeswitch.Event("CUSTOM", "SMS::SEND_MESSAGE");
		event:addHeader("proto", "sip");
		event:addHeader("dest_proto", "sip");
		event:addHeader("from", "sip:" .. from);
		event:addHeader("from_user", from);
		event:addHeader("from_host", domain_name);
		event:addHeader("from_full", "sip:" .. from .."@".. domain_name);
		event:addHeader("sip_profile","internal");
		event:addHeader("to", to);
		event:addHeader("to_user", extension);
		event:addHeader("to_host", domain_name);
		event:addHeader("subject", "SIMPLE MESSAGE");
		event:addHeader("type", "text/plain");
		event:addHeader("hint", "the hint");
		event:addHeader("replying", "true");
		event:addHeader("DP_MATCH", to);
		event:addBody(body);

		if (debug["info"]) then
			freeswitch.consoleLog("info", event:serialize());
		end
		event:fire();
		to = extension;
		
		--Send inbound SMS via email delivery
		if (domain_uuid == nil) then
			--get the domain_uuid using the domain name required for multi-tenant
				if (domain_name ~= nil) then
					sql = "SELECT domain_uuid FROM v_domains ";
					sql = sql .. "WHERE domain_name = :domain_name and domain_enabled = 'true' ";
					local params = {domain_name = domain_name}

					if (debug["sql"]) then
						freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
					end
					status = dbh:query(sql, params, function(rows)
						domain_uuid = rows["domain_uuid"];
					end);
				end
		end
		if (domain_uuid == nil) then
			freeswitch.consoleLog("notice", "[sms] domain_uuid is nill, cannot send sms to email.");
		else
			sql = "SELECT v_contact_emails.email_address ";
			sql = sql .. "from v_extensions, v_extension_users, v_users, v_contact_emails ";
			sql = sql .. "where v_extensions.extension = :toext and v_extensions.domain_uuid = :domain_uuid and v_extensions.extension_uuid = v_extension_users.extension_uuid ";
			sql = sql .. "and v_extension_users.user_uuid = v_users.user_uuid and v_users.contact_uuid = v_contact_emails.contact_uuid ";
			sql = sql .. "and (v_contact_emails.email_label = 'sms' or v_contact_emails.email_label = 'SMS')";
			local params = {toext = extension, domain_uuid = domain_uuid}

			if (debug["sql"]) then
				freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
			end
			status = dbh:query(sql, params, function(rows)
				send_to_email_address = rows["email_address"];
			end);

			--sql = "SELECT domain_setting_value FROM v_domain_settings ";
			--sql = sql .. "where domain_setting_category = 'sms' and domain_setting_subcategory = 'send_from_email_address' and domain_setting_enabled = 'true' and domain_uuid = :domain_uuid";
			--local params = {domain_uuid = domain_uuid}

			--if (debug["sql"]) then
			--	freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
			--end
			--status = dbh:query(sql, params, function(rows)
			--	send_from_email_address = rows["domain_setting_value"];
			--end);
			-- Tried setting the "from" address, above, but default email facility is overriding with global/domain-level default settings.
			send_from_email_address = 'noreply@example.com'  -- this gets overridden if using v_mailto.php
			
			if (send_to_email_address ~= nill and send_from_email_address ~= nill) then
				subject = 'Text Message from: ' .. from;
				emailbody = 'To: ' .. to .. '<br>Msg:' .. body;
				if (debug["info"]) then
					freeswitch.consoleLog("info", emailbody);
				end
				--luarun email.lua send_to_email_address send_from_email_address '' subject emailbody;
				--replace the &#39 with a single quote
					emailbody = emailbody:gsub("&#39;", "'");

				--replace the &#34 with double quote
					emailbody = emailbody:gsub("&#34;", [["]]);

				--send the email
					freeswitch.email(send_to_email_address,
						send_from_email_address,
						"To: "..send_to_email_address.."\nFrom: "..send_from_email_address.."\nX-Headers: \nSubject: "..subject,
						emailbody
						);
			end
		end 

	elseif direction == "outbound" then
		if (argv[3] ~= nil) then
			to_user = argv[3];
			to_user = to_user:gsub("^+?sip%%3A%%40","");
			to = string.match(to_user,'%d+');
		else 
			to = message:getHeader("to_user");
			to = to:gsub("^+?sip%%3A%%40","");
		end
		if (argv[3] ~= nil) then
			domain_name = string.match(to_user,'%@+(.+)');
		else
			domain_name = message:getHeader("from_host");
		end
		if (argv[4] ~= nil) then
			from = argv[4];
			extension = string.match(from,'%d+');
			if extension:len() > 7 then
				outbound_caller_id_number = extension;
			end 
		else
			from = message:getHeader("from_user");
		end
		if (argv[5] ~= nil) then
			body = argv[5];
		else
			body = message:getBody();
		end
		--Clean body up for Groundwire send
		smsraw = body;
		smstempst, smstempend = string.find(smsraw, 'Content%-length:');
		if (smstempend == nil) then
			body = smsraw;
		else
			smst2st, smst2end = string.find(smsraw, '\r\n\r\n', smstempend);
			if (smst2end == nil) then
				body = smsraw;
			else
				body = string.sub(smsraw, smst2end + 1);
			end
		end
		body = body:gsub('%"','');
		--body = body:gsub('\r\n',' ');

		if (debug["info"]) then
			if (message ~= nil) then
				freeswitch.consoleLog("info", message:serialize());
			end
			freeswitch.consoleLog("notice", "[sms] DIRECTION: " .. direction .. "\n");
			freeswitch.consoleLog("notice", "[sms] TO: " .. to .. "\n");
			freeswitch.consoleLog("notice", "[sms] FROM: " .. from .. "\n");
			freeswitch.consoleLog("notice", "[sms] BODY: " .. body .. "\n");
			freeswitch.consoleLog("notice", "[sms] DOMAIN_NAME: " .. domain_name .. "\n");
		end
		
		if (domain_uuid == nil) then
			--get the domain_uuid using the domain name required for multi-tenant
				if (domain_name ~= nil) then
					sql = "SELECT domain_uuid FROM v_domains ";
					sql = sql .. "WHERE domain_name = :domain_name and domain_enabled = 'true' ";
					local params = {domain_name = domain_name}

					if (debug["sql"]) then
						freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
					end
					status = dbh:query(sql, params, function(rows)
						domain_uuid = rows["domain_uuid"];
					end);
				end
		end
		freeswitch.consoleLog("notice", "[sms] DOMAIN_UUID: " .. domain_uuid .. "\n");
		if (outbound_caller_id_number == nil) then
			--get the outbound_caller_id_number using the domain_uuid and the extension number
				if (domain_uuid ~= nil) then
					sql = "SELECT outbound_caller_id_number, extension_uuid, carrier FROM v_extensions ";
					sql = sql .. ", v_sms_destinations ";
					sql = sql .. "WHERE outbound_caller_id_number = destination and  ";
					sql = sql .. "v_extensions.domain_uuid = :domain_uuid and extension = :from and ";
					sql = sql .. "v_sms_destinations.enabled = 'true' and ";
					sql = sql .. "v_extensions.enabled = 'true'";
					local params = {domain_uuid = domain_uuid, from = from}

					if (debug["sql"]) then
						freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
					end
					status = dbh:query(sql, params, function(rows)
						outbound_caller_id_number = rows["outbound_caller_id_number"];
						extension_uuid = rows["extension_uuid"];
						carrier = rows["carrier"];
					end);
				end
		elseif (outbound_caller_id_number ~= nil) then
			--get the outbound_caller_id_number using the domain_uuid and the extension number
				if (domain_uuid ~= nil) then
					sql = "SELECT carrier FROM  ";
					sql = sql .. " v_sms_destinations ";
					sql = sql .. "WHERE destination = :from and ";
					sql = sql .. "v_sms_destinations.domain_uuid = :domain_uuid and ";
					sql = sql .. "enabled = 'true'";
					local params = {from = from, domain_uuid = domain_uuid};

					if (debug["sql"]) then
						freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
					end
					status = dbh:query(sql, params, function(rows)
						carrier = rows["carrier"];
					end);
				end
		end
		
		sql = "SELECT default_setting_value FROM v_default_settings ";
		sql = sql .. "where default_setting_category = 'sms' and default_setting_subcategory = '" .. carrier .. "_access_key' and default_setting_enabled = 'true'";
		local params = {carrier = carrier}

		if (debug["sql"]) then
			freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
		end
		status = dbh:query(sql, function(rows)
			access_key = rows["default_setting_value"];
		end);

		sql = "SELECT default_setting_value FROM v_default_settings ";
		sql = sql .. "where default_setting_category = 'sms' and default_setting_subcategory = '" .. carrier .. "_secret_key' and default_setting_enabled = 'true'";

		if (debug["sql"]) then
			freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
		end
		status = dbh:query(sql, function(rows)
			secret_key = rows["default_setting_value"];
		end);

		sql = "SELECT default_setting_value FROM v_default_settings ";
		sql = sql .. "where default_setting_category = 'sms' and default_setting_subcategory = '" .. carrier .. "_api_url' and default_setting_enabled = 'true'";
		if (debug["sql"]) then
			freeswitch.consoleLog("notice", "[sms] SQL: " .. sql .. "\n");
		end
		status = dbh:query(sql, function(rows)
			api_url = rows["default_setting_value"];
		end);

		--Check for xml content
		smstempst, smstempend = string.find(body, '<%?xml');
		if (smstempst ~= nil) then freeswitch.consoleLog("notice", "[sms] smstempst = '" .. smstempst .. "\n") end;
		if (smstempend ~= nil) then freeswitch.consoleLog("notice", "[sms] smstempend = '" .. smstempend .. "\n") end;
		if (smstempst == nil) then 
			-- No XML content, continue processing
			if (carrier == "flowroute") then
				cmd = "curl -u ".. access_key ..":" .. secret_key .. " -H \"Content-Type: application/json\" -X POST -d '{\"to\":\"" .. to .. "\",\"from\":\"" .. outbound_caller_id_number .."\",\"body\":\"" .. body .. "\"}' " .. api_url;
			elseif (carrier == "twilio") then
				if to:len() < 11 then
					to = "1" .. to;
				end
				if outbound_caller_id_number:len() < 11 then
					outbound_caller_id_number = "1" .. outbound_caller_id_number;
				end
			-- Can be either +1NANNNNXXXX or NANNNNXXXX
				api_url = string.gsub(api_url, "{ACCOUNTSID}",  access_key);
				cmd ="curl -X POST '" .. api_url .."' --data-urlencode 'To=+" .. to .."' --data-urlencode 'From=+" .. outbound_caller_id_number .. "' --data-urlencode 'Body=" .. body .. "' -u ".. access_key ..":" .. secret_key .. " --insecure";
			elseif (carrier == "teli") then
				cmd ="curl -X POST '" .. api_url .."' --data-urlencode 'destination=" .. to .."' --data-urlencode 'source=" .. outbound_caller_id_number .. "' --data-urlencode 'message=" .. body .. "' --data-urlencode 'token=" .. access_key .. "' --insecure";
			elseif (carrier == "plivo") then
				if to:len() <11 then
					to = "1"..to;
				end
				cmd="curl -i --user " .. access_key .. ":" .. secret_key .. " -H \"Content-Type: application/json\" -d '{\"src\": \"" .. outbound_caller_id_number .. "\",\"dst\": \"" .. to .."\", \"text\": \"" .. body .. "\"}' " .. api_url;
			elseif (carrier == "bandwidth") then
				if to:len() <11 then
					to = "1"..to;
				end
				if outbound_caller_id_number:len() < 11 then
					outbound_caller_id_number = "1" .. outbound_caller_id_number;
				end
				cmd="curl -v -X POST " .. api_url .." -u " .. access_key .. ":" .. secret_key .. " -H \"Content-type: application/json\" -d '{\"from\": \"+" .. outbound_caller_id_number .. "\", \"to\": \"+" .. to .."\", \"text\": \"" .. body .."\"}'"		
			elseif (carrier == "thinq") then
				if to:len() < 11 then
					to = "1" .. to;
				end
				if outbound_caller_id_number:len() < 11 then
					outbound_caller_id_number = "1" .. outbound_caller_id_number;
				end
				--Get User_name
				sql = "SELECT default_setting_value FROM v_default_settings ";
				sql = sql .. "where default_setting_category = 'sms' and default_setting_subcategory = '" .. carrier .. "_username' and default_setting_enabled = 'true'";
				if (debug["sql"]) then
					freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
				end
				status = dbh:query(sql, function(rows)
					username = rows["default_setting_value"];
				end);
				cmd = "curl -X POST '" .. api_url .."' -H \"Content-Type:multipart/form-data\"  -F 'message=" .. body .. "' -F 'to_did=" .. to .."' -F 'from_did=" .. outbound_caller_id_number .. "' -u '".. username ..":".. access_key .."'"
			elseif (carrier == "telnyx") then
				if to:len() < 11 then
					to = "1" .. to;
				end
				if outbound_caller_id_number:len() < 11 then
					outbound_caller_id_number = "1" .. outbound_caller_id_number;
				end
				--Get delivery_status_webhook_url
				sql = "SELECT default_setting_value FROM v_default_settings ";
				sql = sql .. "where default_setting_category = 'sms' and default_setting_subcategory = '" .. carrier .. "_delivery_status_webhook_url' and default_setting_enabled = 'true'";
				if (debug["sql"]) then
					freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
				end
				status = dbh:query(sql, function(rows)
					delivery_status_webhook_url = rows["default_setting_value"];
				end);
				cmd ="curl -X POST \"" .. api_url .."\" -H \"Content-Type: application/json\"  -H \"x-profile-secret: " .. secret_key .. "\" -d '{\"from\": \"+" .. outbound_caller_id_number .. "\", \"to\": \"+" .. to .. "\", \"body\": \"" .. body .. "\", \"delivery_status_webhook_url\": \"" .. delivery_status_webhook_url .. "\"}'";
			end
			if (debug["info"]) then
				freeswitch.consoleLog("notice", "[sms] CMD: " .. cmd .. "\n");
			end
			local handle = io.popen(cmd)
			local result = handle:read("*a")
			handle:close()
			if (debug["info"]) then
				freeswitch.consoleLog("notice", "[sms] CURL Returns: " .. result .. "\n");
			end
		else
			-- XML content
			freeswitch.consoleLog("notice", "[sms] Body contains XML content, not sending\n");
		end	
--		os.execute(cmd)
	end
	
--write message to the database
	if (domain_uuid == nil) then
		--get the domain_uuid using the domain name required for multi-tenant
			if (domain_name ~= nil) then
				sql = "SELECT domain_uuid FROM v_domains ";
				sql = sql .. "WHERE domain_name = :domain_name";
				local params = {domain_name = domain_name}

				if (debug["sql"]) then
					freeswitch.consoleLog("notice", "[sms] SQL DOMAIN_NAME: "..sql.."; params:" .. json.encode(params) .. "\n");
				end
				status = dbh:query(sql, params, function(rows)
					domain_uuid = rows["domain_uuid"];
				end);
			end
	end
	if (extension_uuid == nil) then
		--get the extension_uuid using the domain_uuid and the extension number
			if (domain_uuid ~= nil and extension ~= nil) then
				sql = "SELECT extension_uuid FROM v_extensions ";
				sql = sql .. "WHERE domain_uuid = :domain_uuid and extension = :extension";
				local params = {domain_uuid = domain_uuid, extension = extension}

				if (debug["sql"]) then
					freeswitch.consoleLog("notice", "[sms] SQL EXTENSION: "..sql.."; params:" .. json.encode(params) .. "\n");
				end
				status = dbh:query(sql, params, function(rows)
					extension_uuid = rows["extension_uuid"];
				end);
			end
	end
	if (carrier == nil) then
		carrier = '';
	end

	if (extension_uuid ~= nil) then
		sql = "insert into v_sms_messages";
		sql = sql .. "(sms_message_uuid,extension_uuid,domain_uuid,start_stamp,from_number,to_number,message,direction,response,carrier)";
		sql = sql .. " values (:uuid,:extension_uuid,:domain_uuid,now(),:from,:to,:body,:direction,'',:carrier)";
		local params = {uuid = uuid(), extension_uuid = extension_uuid, domain_uuid = domain_uuid, from = from, to = to, body = urlencode(body), direction = direction, carrier = carrier }

		if (debug["sql"]) then
			freeswitch.consoleLog("notice", "[sms] SQL: "..sql.."; params:" .. json.encode(params) .. "\n");
		end
		dbh:query(sql,params);
	end


--]=====]