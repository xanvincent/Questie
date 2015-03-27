DEFAULT_CHAT_FRAME:AddMessage("load", 0.95, 0.95, 0.5);
local function log(msg, level)
	if (level ~= nil and level <= Questie.debugLevel) then
		DEFAULT_CHAT_FRAME:AddMessage(msg)
	end
end

local function debug(msg, category)
	if not (category) then category = true; end
	QuestieDebug[msg] = category;
	--DEFAULT_CHAT_FRAME:AddMessage("Questie has recorded a bugged quest. Please report this to https://github.com/AeroScripts/QuestieDev");
end

Questie = CreateFrame("Frame", "QuestieLua", UIParent, "ActionButtonTemplate")
Questie.TimeSinceLastUpdate = 0
Questie.lastMinimapUpdate = 0
Questie.needsUpdate = false;
Questie.player_x = 0;
Questie.player_y = 0;
Questie.debugLevel = 1;
questsByDistance = {};
selectedNotes = {};
currentNotes = {}; -- needed for minimap and possibly for Cartographer->external database thing
currentNotesControl = {};
QuestieSeenQuests = {};

QuestieNotesDB = {};

local QUESTIE_MAX_MINIMAP_POINTS = 20;

local minimap_poiframes = {};
local minimap_poiframe_textures = {};
local minimap_poiframe_data = {};

function Questie:ADDON_LOADED()
	if not (QuestieCurrentQuests) then
		QuestieCurrentQuests = {};
	end
	if not (QuestieDebug) then
		QuestieDebug = {};
	end	
end

function Questie:createMinimapFrames()
	for i=1,QUESTIE_MAX_MINIMAP_POINTS do
		local fram = CreateFrame("Frame", "QUESTIE_MINIPOI" .. i, Minimap);
		local tex = fram:CreateTexture("ARTWORK"); -- not sure why this needs "ARTWORK"
		tex:SetAllPoints();
		tex:SetTexture("Interface\\AddOns\\Questie\\Icons\\object"); --placeholder
		fram:SetWidth(16);
		fram:SetHeight(16);
		fram:EnableMouse(true);
		local pass = i; -- Apparently you cant just pass i 
		fram:SetScript("OnEnter", function()
			--log("onEnter");
			tex.previousAlpha = tex:GetAlpha();
			tex:SetAlpha(1.0);
			GameTooltip:SetOwner(this, "ANCHOR_BOTTOMLEFT")
			GameTooltip:SetText(minimap_poiframe_data[pass]['progress'], 1, 1, 1);
			GameTooltip:AddLine(minimap_poiframe_data[pass]['name'], 1, 1, 0.1);
			GameTooltip:AddLine(minimap_poiframe_data[pass]['questName'], 0.2, 1, 0.4)
			--GameTooltip:SetPoint(fram:GetPoint());
			GameTooltip:Show();
		end)
		fram:SetScript("OnLeave", function()
			--log("onLeave");
			tex:SetAlpha(tex.previousAlpha);
			GameTooltip:Hide();
		end)
		tex:SetAlpha(0.7);
		minimap_poiframes[i] = fram;
		minimap_poiframe_textures[i] = tex;
	end
end

function Questie:hookTooltip()
	local _GameTooltipOnShow = GameTooltip:GetScript("OnShow") -- APPARENTLY this is always null, and doesnt need to be called for things to function correctly...?
	GameTooltip:SetScript("OnShow", function(self, arg)
		local monster = UnitName("mouseover")
		local objective = GameTooltipTextLeft1:GetText();
		if monster then
			for k,v in pairs(QuestieCurrentQuests) do
				local obj = v['objectives'];
				if not (obj == nil) then --- bad habit I know...
					for l,m in pairs(obj) do
						if m['type'] == "monster" then
							if (monster .. " slain") == m['name'] or monster == m['name'] then
								GameTooltip:AddLine(k, 0.2, 1, 0.3)
								GameTooltip:AddLine("   " .. monster .. ": " .. m['count'], 1, 1, 0.2)
							end
						elseif m['type'] == "item" then
							local monroot = QuestieMonsters[monster];
							if monroot then
								local mondat = monroot['drops'];
								if not (mondat == nil) then
									if mondat[m['name']] then
										GameTooltip:AddLine(k, 0.2, 1, 0.3)
										GameTooltip:AddLine("   " .. m['name'] .. ": " .. m['count'], 1, 1, 0.2)
									end
								end
							end
						end
					end
				end
			end
		elseif objective then
			for k,v in pairs(QuestieCurrentQuests) do
				local obj = v['objectives'];
				if ( obj ) then
					for l,m in pairs(obj) do
						if (m["type"] == "object") then
							local i, j = string.gfind(m["name"], objective);
							if(i and j and QuestieObjects[m["name"]]) then
								GameTooltip:AddLine(k, 0.2, 1, 0.3)
								GameTooltip:AddLine("   " .. m['name'], 1, 1, 0.2)
							end
						elseif (m['type'] == "item" and m['name'] == objective) then
							if(QuestieItems[objective]) then
								GameTooltip:AddLine(k, 0.2, 1, 0.3)
								GameTooltip:AddLine("   " .. m['name'] .. ": " .. m['count'], 1, 1, 0.2)
							end
						end
					end
				end
			end
		end
		GameTooltip:Show() -- recalculates size/position
	end)

end

function Questie:OnEvent() -- functions created in "object:method"-style have an implicit first parameter of "this", which points to object || in 1.12 parsing arguments as ... doesn't work
	Questie[event](Questie, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10) -- route event parameters to Questie:event methods
end
Questie:SetScript("OnEvent", Questie.OnEvent)

local _GetQuestLogQuestText;
local objectives = {};
local throttle = 0;
local throttleOverride = false;

function Questie:modulo(val, by) -- lua5 doesnt support mod math via the % operator :(
	return val - math.floor(val/by)*by
end
function Questie:HashString(text) -- Computes an Adler-32 checksum. (Thanks QuestHelper)
  local a, b = 1, 0
  for i=1,string.len(text) do
    a = Questie:modulo((a+string.byte(text,i)), 65521)
    b = Questie:modulo((b+a), 65521)
  end
  return b*65536+a
end

function Questie:mixString(mix, str)
	return Questie:mixInt(mix, Questie:HashString(str));
end

function Questie:mixInt(hash, addval)
	return bit.lshift(hash, 6) + addval;
end

function Questie:getQuestHash(name, level, objectiveText)

	
	local questLookup = QuestieLevLookup[name];
	if not (questLookup == nil) then -- cant... stop... doingthis....
		--log("QN " .. name .. " is NULL", 1);
		local count = 0;
		local retval = 0;
		local bestDistance = 4294967295; -- some high number (0xFFFFFFFF)
		for k,v in pairs(questLookup) do
			if k == objectiveText then
				return v; -- exact match
			end
			local dist = this:levenshtein(objectiveText, k);
			if dist < bestDistance then
				bestDistance = dist;
				retval = v;
			end
			count = count + 1;
		end
		if not (retval == 0) then
			return retval; -- nearest match
		end
	end
	
	-- hash lookup did not contain qust name!! LOG THIS!!!
	local hash = Questie:mixString(0, name);
	hash = Questie:mixInt(hash, level);
	hash = Questie:mixString(hash, objectiveText);
	return hash;
end


-- Returns the Levenshtein distance between the two given strings
-- credit to https://gist.github.com/Badgerati/3261142
function Questie:levenshtein(str1, str2)
	local len1 = string.len(str1)
	local len2 = string.len(str2)
	local matrix = {}
	local cost = 0
        -- quick cut-offs to save time
	if (len1 == 0) then
		return len2
	elseif (len2 == 0) then
		return len1
	elseif (str1 == str2) then
		return 0
	end
        -- initialise the base matrix values
	for i = 0, len1, 1 do
		matrix[i] = {}
		matrix[i][0] = i
	end
	for j = 0, len2, 1 do
		matrix[0][j] = j
	end
        -- actual Levenshtein algorithm
	for i = 1, len1, 1 do
		for j = 1, len2, 1 do
			if (string.byte(str1,i) == string.byte(str2,j)) then
				cost = 0
			else
				cost = 1
			end
			matrix[i][j] = math.min(matrix[i-1][j] + 1, matrix[i][j-1] + 1, matrix[i-1][j-1] + cost)
		end
	end
        -- return the last value - this is the Levenshtein distance
	return matrix[len1][len2]
end

function Questie:RegisterCartographerIcons()
	Cartographer_Notes:RegisterIcon("Complete", {
		text = "Complete",
		path = "Interface\\AddOns\\Questie\\Icons\\complete",
	})
	Cartographer_Notes:RegisterIcon("Available", {
		text = "Available",
		path = "Interface\\AddOns\\Questie\\Icons\\available",
	})
	Cartographer_Notes:RegisterIcon("Loot", {
		text = "Loot",
		path = "Interface\\AddOns\\Questie\\Icons\\loot",
	})
	Cartographer_Notes:RegisterIcon("Event", {
		text = "Event",
		path = "Interface\\AddOns\\Questie\\Icons\\event",
	})
	Cartographer_Notes:RegisterIcon("Object", {
		text = "Object",
		path = "Interface\\AddOns\\Questie\\Icons\\object",
	})
	Cartographer_Notes:RegisterIcon("Slay", {
		text = "Slay",
		path = "Interface\\AddOns\\Questie\\Icons\\slay",
	})
end

function nql()
	Questie.needsUpdate = true;
	return _GetQuestLogQuestText();
end

local needsRegisterHack = true;

function Questie:OnUpdate(elapsed)
	this = Questie
	if Questie.needsUpdate then
		Questie.needsUpdate = false;
		Questie.throttleOverride = true;
		Questie:QUEST_LOG_UPDATE();
	end
	
	local now = GetTime()
	local ttl = math.abs((now - Questie.lastMinimapUpdate)*1000); -- convert to miliseconds
	
	if ttl > 250 then -- seems about right
		Questie.player_x, Questie.player_y = Questie:getPlayerPos();
		Questie:updateMinimap()
		this = QuestieTracker
		QuestieTracker:fillTrackingFrame()
		this = Questie
		Questie.lastMinimapUpdate = now;
		--log("UMI: " .. Questie.player_x .. ", " .. Questie.player_y);
		--log(now);
	end
	-- Blizzard quest tracker needs to be hidden
	QuestWatchFrame:Hide()
end

function Questie:PLAYER_LOGIN()
	--log(this:GetName())
	this:RegisterEvent("QUEST_LOG_UPDATE");
	this:RegisterEvent("ZONE_CHANGED"); -- this actually is needed
	this:RegisterEvent("UNIT_AURA");
	this:RegisterEvent("UI_INFO_MESSAGE");
	this:RegisterEvent("CHAT_MSG_SYSTEM");
	this:RegisterCartographerIcons();
	this:hookTooltip();
	this:createMinimapFrames();
end

function Questie:UNIT_AURA(unitId)
	--log("UnitID: "..unitId)
end

function Questie:PLAYER_ENTERING_WORLD()
	this:fillQuestList();
	_GetQuestLogQuestText = GetQuestLogQuestText;
	GetQuestLogQuestText = nql;
	this:clearAllNotes();
	this:addAvailableQuests();
end

function Questie:createQuestNote(name, progress, questName, x, y, icon, selected)
	--local id, key = MapNotes_CreateQuestNote(name, lin, olin, x, y, icon, selected)
	--DEFAULT_CHAT_FRAME:AddMessage(icon)
	local zone = Cartographer:GetCurrentEnglishZoneName();
	local _, id, key = Cartographer_Notes:SetNote(zone, x, y, icon, "Questie", "info", progress, "info2", questName, "title", name)
	if (questName == "") then 
		questName = progress; 
	end
	
	this:addNoteToCurrentNotes({
		['id'] = id,
		['x'] = x, 
		['y'] = y,
		['icon'] = icon,
		['questName'] = questName,
		['name'] = name,
		['progress'] = progress,
		['distance'] = 1, -- avoid null error
		['zone'] = zone
	});
	
	this:addNoteToCurrentQuests(questName, id, name, x, y, key, zone, icon);
end

function distance(x, y)
	return math.abs(x-Questie.player_x) + math.abs(y-Questie.player_y);
end

function euclid(x, y)
	local resultX = math.abs(Questie.player_x-x);
	local resultY = math.abs(Questie.player_y-y);
	return math.sqrt(resultX*resultX + resultY*resultY);
end

function sortie(a, b)
	--[[local distA = tonumber(euclid(a['x'], a['y']));
	local distB = tonumber(euclid(b['x'], b['y']));]]
	local distA = Questie:getPlayerDistTo(a['x'], a['y']);
	local distB = Questie:getPlayerDistTo(b['x'], b['y']);
	a['distance'] = distA;
	b['distance'] = distB;
	
	-- while sorted by distance, might as well add formatedDistnace
	local formatDistance, units  = BWP_FormatDist(Questie.player_x, Questie.player_y, a['x'], a['y']);
	a['formatDistance'] = formatDistance;
	a['formatUnits'] = units;
	formatDistance, units  = BWP_FormatDist(Questie.player_x, Questie.player_y, b['x'], b['y']);
	b['formatDistance'] = formatDistance
	b['formatUnits'] = units;
	
	return distA < distB;
end

function Questie:getNearestNotes()
	sort(currentNotes, sortie)
	if ( table.getn(currentNotes) < 1) then
		return;
	end
	return currentNotes[1]['distance'], currentNotes[table.getn(currentNotes)]['distance'];
end

-- for some reason this only shows 3 notes at MAX_NOTES = 5 - 6 at 10 etc
function Questie:updateMinimap()
	local nearest, farthest = Questie:getNearestNotes();
	local index = 1;
	for k,v in pairs(currentNotes) do
		if not (minimap_poiframes[index]) then break; end
		local alpha = (1-(v['distance']/(farthest)));
		local offsX, offsY = getMinimapPosFromCoord(v['x'],v['y'],getCurrentMapID());
		minimap_poiframe_textures[index]:SetTexture("Interface\\AddOns\\Questie\\Icons\\" .. string.lower(v['icon']));
		minimap_poiframe_textures[index]:SetAlpha(alpha);
		minimap_poiframe_data[index] = v;
		minimap_poiframes[index]:SetPoint("CENTER", Minimap, "CENTER", offsX, -offsY);
		minimap_poiframes[index]:Show();
		index = index + 1;	
	end
end

function Questie:deleteCurrentNotesforQuest(questName)

	local i = 1;
	while i <= table.getn(currentNotes) do
		local v = currentNotes[i];
		if(v["questName"] == questName) then
			table.remove(currentNotes, i);
			this:removeNoteFromCurrentNotes(v);
		else
			i = i + 1;
		end
	end
end

function Questie:addNoteToCurrentNotes(note)
	if not ( currentNotesControl[note['id']] ) then
		currentNotesControl[note['id']] = true;
		table.insert(currentNotes, note);
	end
end

-- needs to be called on clearAllNotes, deleteNoteAfterQuestRemoved, etc
function Questie:removeNoteFromCurrentNotes(note)
	currentNotesControl[note['id']] = nil;
	-- find in currentNotes and delete too
	-- probably no way around iterating the table to remove it UNLESS we store its key in currentNotesControl (table.getn()+1, before inserting)
end

function Questie:addNoteToCurrentQuests(questName, id, name, x, y, key, zone, icon)
	if(QuestieCurrentQuests[questName] ~= nil) then
		if(type(QuestieCurrentQuests[questName]["notes"]) ~= "table") then
			QuestieCurrentQuests[questName]["notes"] = {}
		end
		--log("adding notes to quest list for quest "..questName)
		--log(name)
		--log(key)
		--log(zone)
		--log(id)
		QuestieCurrentQuests[questName]["notes"][id] = {
			['name'] = name,
			['x'] = x,
			['y'] = y,
			['id'] = id,
			['icon'] = icon,
			['key'] = key,
			['zone'] = zone,
			['icon'] = icon
		};
	end
end

function Questie:addMonsterToMap(monsterName, info, quest, icon, mapid, selected)
	local monsterdata = QuestieMonsters[monsterName];
	if not (monsterdata == nil) then
		local foundNotes = false;
		for b=1,monsterdata['locationCount'] do -- this should be made more efficient (monsterdata[mapid][locations] etc
			local loc = monsterdata['locations'][b];
			if loc[1] == mapid then
				this:createQuestNote(monsterName, info, quest, loc[2], loc[3], icon, selected);
				foundNotes = true;
			end
		end
		if (foundNotes == false) then
			debug("ERROR NO NOTES  " .. quest .. "  monster:  " .. monsterName .."  on map  ".. mapid);
		end
	else
		debug("ERROR UNKNOWN MONSTER " .. quest .. "  monster:" .. monsterName);
	end
end

function Questie:clearAllNotes()
	selectedNotes = {}
	currentNotes = {} -- temp fix
	Cartographer_Notes:ClearMap();
end

function Questie:getPlayerPos()

-- thanks to mapnotes for this "bug fix"
	local fx, fy = GetPlayerMapPosition("player");
	if ( ( ( fx ) and ( fx == 0 ) ) and ( ( fy ) and ( fy == 0 ) ) ) then
		SetMapToCurrentZone();
	end
	-- thanks mapnotes
	return fx, fy;
end

function getCurrentMapID()

	
	local fx, fy = Questie:getPlayerPos(); -- this: does not work here??

	local file = GetMapInfo()
	
	if file == nil then -- thanks optim for finding a null bug here
		return -1
	end
	
	local zid = QuestieZones[file];
	if zid == nil then
		DEFAULT_CHAT_FRAME:AddMessage("ERROR: We are in unknown zone " .. file, 0.95, 0.2, 0.2);
		return -1
	else
		return zid[1];
	end
end

function Questie:addAvailableQuests()
	local mapid = getCurrentMapID();
	local level = UnitLevel("Player");
	for l=level-3,level+2 do
		if QuestieZoneLevelMap[mapid] then
			local content = QuestieZoneLevelMap[mapid][l];
			if not (content == nil) then
				for k,v in pairs(content) do
					if not QuestieSeenQuests[v] then
						local qdata = QuestieHashMap[v];
						--log(" value [" .. v .. "] !!!= " .. qdata['name'],1);
						if not (qdata == nil) then
							local requires = qdata['requires'];
							if requires == nil then
								local stype = qdata['startedType'];
								local sby = qdata['startedBy'];
								local name = qdata['name'];
								if stype == "monster" then
									local mob = QuestieMonsters[sby];
									local loc = mob['locations'][1];
									this:createQuestNote("Pick up: " .. name, sby, name, loc[2], loc[3], "Available", selected);
									--createQuestNote("Pick up: " .. name, sby, stype, loc[2], loc[3], 9, false);
								end
							end
						end
					end
				end
			end
		end
	end
end

objectiveProcessors = {
	['item'] = function(quest, name, amount, selected, mapid)
		--DEFAULT_CHAT_FRAME:AddMessage("derp", 0.95, 0.95, 0.5);
		local itemdata = QuestieItems[name];
		if itemdata == nil then
			debug("ERROR PROCESSING " .. quest .. "  objective:" .. name);
		else
			for k,v in pairs(itemdata) do
				if k == "locationCount" then
					for b=1,itemdata['locationCount'] do
						local loc = itemdata['locations'][b];
						if loc[1] == mapid then
							Questie:createQuestNote(name, quest, "", loc[2], loc[3], "Loot", selected);
						end
					end
				elseif k == "drop" then
					for e,r in pairs(v) do
						--local monsterdata = QuestRoot['QuestHelper_StaticData']['enUS']['objective']['monster'][e];
						--addMonsterToMap(monsterName, info, quest, selected)
						Questie:addMonsterToMap(e, name .. " (" .. amount .. ")", quest, "Loot", mapid, selected);
					end
				else
					debug("ERROR PROCESSING " .. quest .. "  objective:" .. name);
				end
			end
		end
	end,
	['event'] = function(quest, name, amount, selected, mapid)
		local evtdata = QuestieEvents[name]
		if evtdata == nil then
			debug("ERROR UNKNOWN EVENT " .. quest .. "  objective:" .. name);
		else
			--DEFAULT_CHAT_FRAME:AddMessage("VALIDEVT: " .. name, 0.2, 0.95, 0.2);
			for b=1,evtdata['locationCount'] do
				local loc = evtdata['locations'][b];
				if loc[1] == mapid then
					Questie:createQuestNote(name, quest, "", loc[2], loc[3], "Event", selected);
				end
			end
		end
	end,
	['monster'] = function(quest, name, amount, selected, mapid)
		--DEFAULT_CHAT_FRAME:AddMessage("   MONMON: " .. quest .. ", " .. name .. ", " .. amount, 0.95, 0.2, 0.2);
		Questie:addMonsterToMap(name, amount, quest, "Slay", mapid, selected);
	end,
	['object'] = function(quest, name, amount, selected, mapid)
		local objdata = QuestieObjects[name];
		if objdata == nil then
			debug("ERROR UNKNOWN OBJECT " .. quest .. "  objective:" .. name);
		else
			for b=1,objdata['locationCount'] do
				local loc = objdata['locations'][b];
				if loc[1] == mapid then
					Questie:createQuestNote(name, quest, "", loc[2], loc[3], "Object", selected);
				end
			end
		end
	end

}

function Questie:getQuestFinisherByName(name)

end

function findLast(haystack, needle)
    local i=string.gfind(haystack, ".*"..needle.."()")()
    if i==nil then return nil else return i-1 end
end

function Questie:processObjective(quest, desc, typ, selected, mapid, objectiveid)
	--DEFAULT_CHAT_FRAME:AddMessage(desc, 0.95, 0.95, 0.5);
	local ref = objectiveProcessors[typ];
	
	if not (ref == nil) then
		--DEFAULT_CHAT_FRAME:AddMessage("HANDLED TYPE: " .. typ .. " for quest " .. quest, 0.2, 0.95, 0.95);
		if typ == "item" or typ == "monster" then
			local indx = findLast(desc, ":");
			--DEFAULT_CHAT_FRAME:AddMessage(indx, 0.95, 0.95, 0.5);
			local countstr = string.sub(desc, indx+2);
			local namestr = string.sub(desc, 1, indx-1);
			QuestieCurrentQuests[quest]['objectives'][objectiveid] = {
				['name'] = namestr,
				['count'] = countstr,
				['type'] = typ
			};
			ref(quest, namestr, countstr, selected, mapid);
		else
			ref(quest, desc, "", selected, mapid);
			QuestieCurrentQuests[quest]['objectives'][objectiveid] = {
				['name'] = desc,
				['count'] = -1,
				['type'] = typ
			};
		end
	else
		debug("ERROR: UNHANDLED TYPE: " .. typ .. " \"" .. desc .. "\" for quest " .. quest);
	end
end

function getQuestHashByName(name)
	return QuestieHashes[name];
end

function Questie:QUEST_LOG_UPDATE()
	this:deleteNoteAfterQuestRemoved()
		
	local sind = GetQuestLogSelection();
	local mapid = getCurrentMapID();
	if not throttleOverride then
		if throttle == math.floor(GetTime()) then
			return
		else
			throttle = math.floor(GetTime())
		end
	else
		throttleOverride = false;
	end
	
	--DEFAULT_CHAT_FRAME:AddMessage(throttle, 0.95, 0.95, 0.5);
	--this:clearAllNotes();
	Questie:addAvailableQuests();
	local numEntries, numQuests = GetNumQuestLogEntries()
	--DEFAULT_CHAT_FRAME:AddMessage(numEntries .. " entries containing " .. numQuests .. " quests in your quest log.");
	for v=1,numEntries do
		local q, level, questTag, isHeader, isCollapsed, isComplete = GetQuestLogTitle(v);
		if not isHeader then
            SelectQuestLogEntry(v);
            local count =  GetNumQuestLeaderBoards();
            local selected = v == sind;
            local questComplete = true; -- there might be something in the api for this	
            local questText, objectiveText = _GetQuestLogQuestText();
            local hash = Questie:getQuestHash(q, level, objectiveText);
			--log("QH:"..q..","..level..","..objectiveText.."="..hash,1);
            local hashData = QuestieHashMap[hash];
                
            if hash and not isHeader then
                local seen = QuestieSeenQuests[hash];
                if QuestieCurrentQuests[q] == nil then
                    QuestieCurrentQuests[q] = {};
                end
                QuestieCurrentQuests[q]['hash'] = hash; -- needs to store the hash (probably not best to set it every time)
                --log("SEEN " .. q .. " as hash " .. hash, 1)
                if seen == nil or not seen then -- not seen would update it if the user had abandoned then re-picked up
                                                -- someone should tell me if LUA is like C where I could do only "if not seen then" here.
                    QuestieSeenQuests[hash] = true; -- true = in the quest log
                end
                
                if not (hashData == nil) then
                    --log(hashData['finishedBy'], 1);
                    if (count == 0) then
                        Questie:addMonsterToMap(hashData['finishedBy'], "Quest Finisher", q, "Complete", mapid, selected);
                        questComplete = false; -- questComplete is used to add the finisher, this avoids adding it twice
                    end
                else
                    local finisher = QuestieFinishers[q];
                
                    if not (finisher == nil) and (count == 0) then
                        Questie:addMonsterToMap(finisher, "Quest Finisher", q, "Complete", mapid, selected);
                        questComplete = false; -- questComplete is used to add the finisher, this avoids adding it twice
                    end
                end
                --DEFAULT_CHAT_FRAME:AddMessage(q);
                
                -- we're re-evaluating objectives now anyway
                QuestieCurrentQuests[q]['objectives'] = {};
                
                for r=1,count do
                    local desc, typ, done = GetQuestLogLeaderBoard(r);
                    --DEFAULT_CHAT_FRAME:AddMessage(desc, 0.95, 0.95, 0.5);
                    
                    
                    if not done then
                        questComplete = false;
                        if selected then
                            --DEFAULT_CHAT_FRAME:AddMessage("SELECTED " .. q, 0.95, 0.1, 0.95);
                        else
                            --DEFAULT_CHAT_FRAME:AddMessage("NOTSELECTEd " .. q .. " " .. in, 0.95, 0.1, 0.95);
                        end
                        this:processObjective(q, desc, typ, selected, mapid, r)
                    end
                    ---DEFAULT_CHAT_FRAME:AddMessage(typ, 0.95, 0.95, 0.5);
                    ---DEFAULT_CHAT_FRAME:AddMessage(done, 0.95, 0.95, 0.5);
                    
                end
                if not (hashData == nil) then
                    --log(hashData['finishedBy'], 1);
                    if isComplete then
                        Questie:addMonsterToMap(hashData['finishedBy'], "Quest Finisher", q, "Complete", mapid, selected);
                        questComplete = false; -- questComplete is used to add the finisher, this avoids adding it twice
                    end
                else
                    local finisher = QuestieFinishers[q];
                
                    if not (finisher == nil) and isComplete then
                        Questie:addMonsterToMap(finisher, "Quest Finisher", q, "Complete", mapid, selected);
                        questComplete = false; -- questComplete is used to add the finisher, this avoids adding it twice
                    end
                end
                --DEFAULT_CHAT_FRAME:AddMessage(hash);
            elseif not hash and not isHeader then
                debug("ERROR: UNKNOWN QUEST: " .. q);
            end
        end
	end
	SelectQuestLogEntry(sind);
end

local lastZoneID = 0;

function Questie:ZONE_CHANGED() -- this is needed
	local map = getCurrentMapID();
	if not (map == lastZoneID) then -- I cant seem to get over this weird LUA not operator...
		this:QUEST_LOG_UPDATE();
		lastZoneID = map
	end
end

function Questie:UI_INFO_MESSAGE(message)
	--log(message, 1)
end

function Questie:removeAvailableMarker(name) -- this needs to be handled differently anyway
	for id, note in pairs(currentNotes) do	
		--log(id, 1)
		if note['icon'] == "Available" then
			--log(, 1)
			if note['questName'] == name then
				table.remove(currentNotes, id);
				this:removeNoteFromCurrentNotes(note);
				Cartographer_Notes:DeleteNote(note["zone"], note["x"], note["y"]);
			end
		end--else log(note['icon'], 1); end
	end
	--removeNoteFromCurrentNotes
end

function Questie:CHAT_MSG_SYSTEM(message)
	--log(message, 1)
	local index = findLast(message, ":");
	if tonumber(index) == 15 then -- quest accepted
		local questName = string.sub(message, index+2);
		--log("Accepted " .. questName, 1)
		Questie:removeAvailableMarker(questName)
	end
end


function Questie:deleteNoteAfterQuestRemoved()
	local finishedQuest = this:getFinishedQuest();
	if (finishedQuest ~= nil) then
		if( QuestieCurrentQuests[finishedQuest]['hash'] ) then
			QuestieSeenQuests[QuestieCurrentQuests[finishedQuest]['hash']] = false; -- no longer in the list
		end
		--log("finished or abandoned quest " .. finishedQuest)
		local notes = QuestieCurrentQuests[finishedQuest]["notes"]
		if (notes ~= nil) then
			for k,v in pairs(notes) do
				--log(v["zone"] .. "  " .. v["x"] .. "  " .. v["y"])
				Cartographer_Notes:DeleteNote(v["zone"], v["x"], v["y"]);
			end
		end
		--log("Deleting notes for quest:" .. finishedQuest);
		this:deleteCurrentNotesforQuest(finishedQuest);
		QuestieCurrentQuests[finishedQuest] = nil;
	end
end

function Questie:getFinishedQuest()
	this:validateQuestList();
	for k,v in pairs(QuestieCurrentQuests) do
		if (v['status'] == false) then
			return k;
		end
	end
end

function Questie:fillQuestList()
	for i=1, GetNumQuestLogEntries() do
		local questLogTitleText, level, questTag, isHeader, isCollapsed, isComplete = GetQuestLogTitle(i);
		if not (isHeader) then
			if(type(QuestieCurrentQuests[questLogTitleText]) ~= "table") then
				QuestieCurrentQuests[questLogTitleText] = {}
			end
			QuestieCurrentQuests[questLogTitleText]['status'] = true;
			--log("setting " .. GetQuestLogTitle(i) .. " true");
		end
	end
end

function Questie:validateQuestList()
	for k,v in pairs(QuestieCurrentQuests) do
		v['status'] = false;
		--log("setting "..k.." to false");
	end
	
	this:fillQuestList();
end

--taken from MetaMapBWP

function BWP_GetDist(x1, y1, x2, y2)
	if(not x1) or (not x2) then return nil 
	else return math.sqrt((x1 - x2)^2 + (y1 - y2)^2)
	end
end

--formats to yards or meters or clicks
function BWP_FormatDist(x1, y1, x2, y2)
	local thisDistance = BWP_GetDist(x1, y1, x2, y2)
	thisDistance = Questie:ConvertToYards(x1, y1, x2, y2) / 10;
	if(true) then
		theseUnits = " Yds"
	else
		thisDistance = thisDistance * 0.9144	
		theseUnits = " Mtrs"
	end
	thisDistance = tonumber(string.format("%.0f" , thisDistance)) -- we dont really need decimal places with this small of units
	return thisDistance, theseUnits
end

function Questie:ConvertToYards(x1, y1, x2, y2)
	if(x1 == nil) then
		x1, y1, x2, y2 = 0, 0, 0, 0;
	end
   -- I think the 40482 thing should be taken from some map scale table? Can't find anything I understand though
   local dx = (x1 - x2) * 40482.686754239;
   local dy = (y1 - y2) * (40482.686754239 / 1.5);
   return math.sqrt(dx * dx + dy * dy)
end

function Questie:getPlayerDistTo(x, y)
	return BWP_GetDist(Questie.player_x, Questie.player_y, x, y);
end