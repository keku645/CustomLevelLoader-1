class "LevelLoader"

local m_Logger = Logger("LevelLoader", true)

GameObjectOriginType = {
	Vanilla = 1,
	Custom = 2,
	CustomChild = 3
}

local CLIENT_TIMEOUT = 25

function LevelLoader:__init()
    m_Logger:Write("LevelLoader init.")

    self:RegisterVars()
    self:RegisterEvents()
end

function LevelLoader:RegisterVars()
    self.m_PrimaryLevelGuids = {}

    self.m_IndexCount = 0
    self.m_OriginalLevelIndeces = {}
    self.m_LastLoadedMap = nil
    self.m_ObjectVariations = {}
    self.m_PendingVariations = {}
    self.m_CustomLevelData = {}

end

function LevelLoader:RegisterEvents()
    -- nº 1 in calling order
    Events:Subscribe('Level:LoadResources', self, self.OnLoadResources)

    -- nº 2 in calling order
    Events:Subscribe('Partition:Loaded', self, self.OnPartitionLoaded)

    -- nº 3 in calling order
    Events:Subscribe('Level:LoadingInfo', self, self.OnLevelLoadingInfo)

    -- Remove all DataContainer references and reset vars
    Events:Subscribe('Level:Destroy', self, self.OnLevelDestroy)

    ResourceManager:RegisterInstanceLoadHandler(Guid('C4DCACFF-ED8F-BC87-F647-0BC8ACE0D9B4'), Guid('B479A8FA-67FF-8825-9421-B31DE95B551A'), function(p_Instance)
        p_Instance = ClientSettings(p_Instance)
        p_Instance:MakeWritable()
        p_Instance.loadedTimeout = CLIENT_TIMEOUT
        p_Instance.loadingTimeout = CLIENT_TIMEOUT
        p_Instance.ingameTimeout = CLIENT_TIMEOUT
        print("Changed ClientSettings")
    end)

    ResourceManager:RegisterInstanceLoadHandler(Guid('C4DCACFF-ED8F-BC87-F647-0BC8ACE0D9B4'), Guid('818334B3-CEA6-FC3F-B524-4A0FED28CA35'), function(p_Instance)
        p_Instance = ServerSettings(p_Instance)
        p_Instance:MakeWritable()
        p_Instance.loadingTimeout = CLIENT_TIMEOUT
        p_Instance.ingameTimeout = CLIENT_TIMEOUT
        p_Instance.timeoutTime = CLIENT_TIMEOUT
        print("Changed ServerSettings")
    end)
end

function LevelLoader:OnLoadResources()
    m_Logger:Write("Loading resources")
    self.m_ObjectVariations = {}
    self.m_PendingVariations = {}
    self.m_CustomLevelData = self:GetCustomLevel(SharedUtils:GetLevelName(), SharedUtils:GetCurrentGameMode())
end

function LevelLoader:OnPartitionLoaded(p_Partition)
    if not self.m_CustomLevelData then
        return
    end

    if p_Partition == nil then
        return
    end

    local s_PrimaryInstance = p_Partition.primaryInstance

    if s_PrimaryInstance == nil then
        m_Logger:Warn('Instance is null?')
        return
    end
    -- if l_Instance:Is("Blueprint") then
        --print("-------"..Blueprint(l_Instance).name)
    -- end
    if s_PrimaryInstance.typeInfo.name == "LevelData" then
        local s_Instance = LevelData(s_PrimaryInstance)
        if (s_Instance.name == SharedUtils:GetLevelName()) then
            m_Logger:Write("----Registering PrimaryLevel guids")
            s_Instance:MakeWritable()

            self.m_PrimaryLevelGuids = {
                instanceGuid = s_Instance.instanceGuid,
                partitionGuid = s_Instance.partitionGuid
            }
        end
    elseif s_PrimaryInstance:Is('ObjectVariation') then
        -- Store all variations in a map.
        local s_Variation = ObjectVariation(s_PrimaryInstance)
        self.m_ObjectVariations[s_Variation.nameHash] = s_Variation
        if self.m_PendingVariations[s_Variation.nameHash] ~= nil then
            for _, l_Object in pairs(self.m_PendingVariations[s_Variation.nameHash]) do
                l_Object.objectVariation = s_Variation
            end

            self.m_PendingVariations[s_Variation.nameHash] = nil
        end
    end
end

function LevelLoader:OnLevelLoadingInfo(p_Info)
    if not self.m_CustomLevelData then
        return
    end

    if p_Info == "Registering entity resources" then
        m_Logger:Write("-----Loading Info - Registering entity resources")

        -- TODO: why this check again?
        if not self.m_CustomLevelData then
            m_Logger:Warn("No custom level specified.")
            return
        end

        if self.m_PrimaryLevelGuids == nil then
            m_Logger:Warn("m_PrimaryLevelGuids is nil, something went wrong")
            return
        end

        local s_PrimaryLevel = ResourceManager:FindInstanceByGuid(self.m_PrimaryLevelGuids.partitionGuid, self.m_PrimaryLevelGuids.instanceGuid)

        if s_PrimaryLevel == nil then
            m_Logger:Warn("Couldn\'t find PrimaryLevel DataContainer, aborting")
            return
        end

        s_PrimaryLevel = LevelData(s_PrimaryLevel)

        if self.m_LastLoadedMap == SharedUtils:GetLevelName() then
            m_Logger:Write('Same map loading, skipping')
            return
        end

        m_Logger:Write("Patching level")
        local s_RegistryContainer = s_PrimaryLevel.registryContainer
        if s_RegistryContainer == nil then
            m_Logger:Error('No registryContainer found, this shouldn\'t happen')
        end
        s_RegistryContainer = RegistryContainer(s_RegistryContainer)
        s_RegistryContainer:MakeWritable()

        local s_WorldPartReference = self:CreateWorldPart(s_PrimaryLevel, s_RegistryContainer)

        s_WorldPartReference.indexInBlueprint = #s_PrimaryLevel.objects

        s_PrimaryLevel.objects:add(s_WorldPartReference)

        -- Save original indeces in case LevelData has to be reset to default state later.
        self.m_OriginalLevelIndeces = {
            objects = #s_PrimaryLevel.objects,
            ROFs = #s_RegistryContainer.referenceObjectRegistry,
            blueprints = #s_RegistryContainer.blueprintRegistry,
            entity = #s_RegistryContainer.entityRegistry
        }
        s_RegistryContainer.referenceObjectRegistry:add(s_WorldPartReference)
        m_Logger:Write('Level patched')
    end
end

function LevelLoader:OnLevelDestroy()
    self.m_ObjectVariations = {}
    self.m_PendingVariations = {}
    self.m_IndexCount = 0

    -- TODO: remove all custom objects from level registry and leveldata if next round is
    -- the same map but a different save, once that is implemented. If it's a different map
    -- there is no need to clear anything, as the leveldata will be unloaded and a new one loaded
end

function LevelLoader:PatchOriginalObject(p_Object, p_World)
	if p_Object.originalRef == nil then
		print("Object without original reference found, dynamic object?")
		return
	end
	local s_Reference = nil
	if p_Object.originalRef.partitionGuid == nil or p_Object.originalRef.partitionGuid == "nil" then -- perform a search without partitionguid
		 s_Reference = ResourceManager:SearchForInstanceByGuid(Guid(p_Object.originalRef.instanceGuid))
		 if s_Reference == nil then
		 	print("Unable to find original reference: " .. p_Object.originalRef.instanceGuid)
		 	return
		 end
	else
		 s_Reference = ResourceManager:FindInstanceByGuid(Guid(p_Object.originalRef.partitionGuid), Guid(p_Object.originalRef.instanceGuid))
		 if s_Reference == nil then
		 	print("Unable to find original reference: " .. p_Object.originalRef.instanceGuid .. " in partition " .. p_Object.originalRef.partitionGuid)
		 	return
		 end
	end
	s_Reference = _G[s_Reference.typeInfo.name](s_Reference)
	s_Reference:MakeWritable()
	if p_Object.isDeleted then
		s_Reference.excluded = true
	end
	if p_Object.localTransform then
		s_Reference.blueprintTransform = LinearTransform(p_Object.localTransform) -- LinearTransform(p_Object.localTransform)
	else
		s_Reference.blueprintTransform = LinearTransform(p_Object.transform) -- LinearTransform(p_Object.transform)
	end
end

function LevelLoader:AddCustomObject(p_Object, p_World, p_RegistryContainer)
	local s_Blueprint = ResourceManager:FindInstanceByGuid(Guid(p_Object.blueprintCtrRef.partitionGuid), Guid(p_Object.blueprintCtrRef.instanceGuid))
	if s_Blueprint == nil then
		print('Cannot find blueprint with guid ' .. tostring(p_Object.blueprintCtrRef.instanceGuid))
		return
	end

	-- Filter BangerEntityData.
	if s_Blueprint:Is('ObjectBlueprint') then
		local s_ObjectBlueprint = ObjectBlueprint(s_Blueprint)
		if s_ObjectBlueprint.object and s_ObjectBlueprint.object:Is('BangerEntityData') then
			return
		end
	end

	local s_Reference
	if s_Blueprint:Is('EffectBlueprint') then
		s_Reference = EffectReferenceObjectData()
		s_Reference.autoStart = true
	else
		s_Reference = ReferenceObjectData()
	end

	p_RegistryContainer.referenceObjectRegistry:add(s_Reference)
	if p_Object.localTransform then
		s_Reference.blueprintTransform = LinearTransform(p_Object.localTransform)
	else
		s_Reference.blueprintTransform = LinearTransform(p_Object.transform)
	end
	--print("AddCustomObject: " .. p_Object.transform)
	s_Reference.blueprint = Blueprint(s_Blueprint)
	-- s_Reference.blueprint:MakeWritable()

	if self.m_ObjectVariations[p_Object.variation] == nil then
		self.m_PendingVariations[p_Object.variation] = s_Reference
	else
		s_Reference.objectVariation = self.m_ObjectVariations[p_Object.variation]
	end
	s_Reference.indexInBlueprint = #p_World.objects + self.m_IndexCount + 1
	s_Reference.isEventConnectionTarget = Realm.Realm_None
	s_Reference.isPropertyConnectionTarget = Realm.Realm_None
	s_Reference.castSunShadowEnable = true
	s_Reference.excluded = false

	p_World.objects:add(s_Reference)
end


function LevelLoader:CreateWorldPart(p_PrimaryLevel, p_RegistryContainer)
	local s_World = WorldPartData()
	p_RegistryContainer.blueprintRegistry:add(s_World)

	--find index
	for _, l_Object in pairs(p_PrimaryLevel.objects) do
		if l_Object:Is('WorldPartReferenceObjectData') then
			local l_RefObjectData = WorldPartReferenceObjectData(l_Object)
			if l_RefObjectData.blueprint:Is('WorldPartData') then
				local s_WorldPart = WorldPartData(l_RefObjectData.blueprint)
				if #s_WorldPart.objects ~= 0 then
					local s_ROD = s_WorldPart.objects[#s_WorldPart.objects] -- last one in array
					if s_ROD and s_ROD:Is('ReferenceObjectData') then
						s_ROD = ReferenceObjectData(s_ROD)
						if s_ROD.indexInBlueprint > self.m_IndexCount then
							self.m_IndexCount = s_ROD.indexInBlueprint
						end
					end
				end
			end
		end
	end
	-- m_IndexCount = 30000
	print('Index count is: '..tostring(self.m_IndexCount))

	for _, l_Object in pairs(self.m_CustomLevelData.data) do
		if l_Object.origin == GameObjectOriginType.Custom then
			if not self.m_CustomLevelData.vanillaOnly then
				self:AddCustomObject(l_Object, s_World, p_RegistryContainer)
			end
		elseif l_Object.origin == GameObjectOriginType.Vanilla then
			self:PatchOriginalObject(l_Object, s_World)
		end
		-- TODO handle CustomChild
	end
	self.m_LastLoadedMap = SharedUtils:GetLevelName()

	local s_WorldPartReference = WorldPartReferenceObjectData()
	s_WorldPartReference.blueprint = s_World

	s_WorldPartReference.isEventConnectionTarget = Realm.Realm_None
	s_WorldPartReference.isPropertyConnectionTarget = Realm.Realm_None
	s_WorldPartReference.excluded = false

	return s_WorldPartReference
end

function LevelLoader:GetCustomLevel(p_LevelName, p_GameModeName)
	print(p_LevelName)
	print(p_GameModeName)
	local s_LevelName = p_LevelName:split('/')[3]
	print(s_LevelName)

	local s_Path = '__shared/Levels/' .. s_LevelName .. '/' .. s_LevelName .. '_' .. p_GameModeName

	print(s_Path)

	local s_Ok, s_PresetJson = pcall(require, s_Path)
	s_PresetJson = s_Ok and s_PresetJson or nil

    if not s_PresetJson then
        m_Logger:Write('Couldnt find custom level data for Level: ' .. p_LevelName .. ' - GameMode: ' .. p_GameModeName)
        return nil
    end

    local s_Preset = json.decode(s_PresetJson)

    if not s_Preset then
        m_Logger:Error('Couldnt decode json preset')
        return nil
    end

	m_Logger:Write("preset found: " .. s_Path:split('/')[4])

    return s_Preset
end

function string:split(sep)
	local sep, fields = sep or ":", {}
	local pattern = string.format("([^%s]+)", sep)
	self:gsub(pattern, function(c) fields[#fields+1] = c end)
	return fields
end

-- Singleton.
if g_LevelLoader == nil then
	g_LevelLoader = LevelLoader()
end

return g_LevelLoader