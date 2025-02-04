﻿local _, Addon = ...
local t = Addon.ThreatPlates

---------------------------------------------------------------------------------------------------
-- Imported functions and constants
---------------------------------------------------------------------------------------------------

-- Lua APIs
local tonumber, pairs = tonumber, pairs

-- WoW APIs
local SetNamePlateFriendlyClickThrough = C_NamePlate.SetNamePlateFriendlyClickThrough
local SetNamePlateEnemyClickThrough = C_NamePlate.SetNamePlateEnemyClickThrough
local UnitName, IsInInstance, InCombatLockdown = UnitName, IsInInstance, InCombatLockdown
local GetCVar, IsAddOnLoaded = GetCVar, IsAddOnLoaded
local C_NamePlate, Lerp =  C_NamePlate, Lerp
local C_Timer_After = C_Timer.After
local NamePlateDriverFrame = NamePlateDriverFrame

-- ThreatPlates APIs
local TidyPlatesThreat = TidyPlatesThreat
local LibStub = LibStub
local L = t.L

local _G =_G
-- Global vars/functions that we don't upvalue since they might get hooked, or upgraded
-- List them here for Mikk's FindGlobals script
-- GLOBALS: SetCVar

---------------------------------------------------------------------------------------------------
-- Local variables
---------------------------------------------------------------------------------------------------
local task_queue_ooc = {}
local LSMUpdateTimer

---------------------------------------------------------------------------------------------------
-- Global configs and funtions
---------------------------------------------------------------------------------------------------

t.Print = function(val,override)
  local db = TidyPlatesThreat.db.profile
  if override or db.verbose then
    print(t.Meta("titleshort")..": "..val)
  end
end

function TidyPlatesThreat:SpecName()
  local _,name,_,_,_,role = GetSpecializationInfo(GetSpecialization(false,false,1),nil,false)
  if name then
    return name
  else
    return L["Undetermined"]
  end
end

local tankRole = L["|cff00ff00tanking|r"]
local dpsRole = L["|cffff0000dpsing / healing|r"]

function TidyPlatesThreat:RoleText()
  if Addon:PlayerRoleIsTank() then
    return tankRole
  else
    return dpsRole
  end
end

local EVENTS = {
  --"PLAYER_ALIVE",
  --"PLAYER_LEAVING_WORLD",
  --"PLAYER_TALENT_UPDATE"

  "PLAYER_ENTERING_WORLD",
  "PLAYER_LOGIN",
  --"PLAYER_LOGOUT",
  "PLAYER_REGEN_ENABLED",
  "PLAYER_REGEN_DISABLED",

  -- CVAR_UPDATE,
  -- DISPLAY_SIZE_CHANGED,     -- Blizzard also uses this event
  -- VARIABLES_LOADED,         -- Blizzard also uses this event

  -- Events from TidyPlates

  -- NAME_PLATE_CREATED
  -- NAME_PLATE_UNIT_ADDED
  -- UNIT_NAME_UPDATE
  -- NAME_PLATE_UNIT_REMOVED

  -- PLAYER_TARGET_CHANGED
  -- UPDATE_MOUSEOVER_UNIT

  -- UNIT_HEALTH_FREQUENT
  -- UNIT_MAXHEALTH,
  -- UNIT_ABSORB_AMOUNT_CHANGED,

  -- PLAYER_REGEN_ENABLED
  -- PLAYER_REGEN_DISABLED

  -- UNIT_SPELLCAST_START
  -- UNIT_SPELLCAST_STOP
  -- UNIT_SPELLCAST_CHANNEL_START
  -- UNIT_SPELLCAST_CHANNEL_STOP
  -- UNIT_SPELLCAST_DELAYED
  -- UNIT_SPELLCAST_CHANNEL_UPDATE
  -- UNIT_SPELLCAST_INTERRUPTIBLE
  -- UNIT_SPELLCAST_NOT_INTERRUPTIBLE

  -- UI_SCALE_CHANGED
  -- COMBAT_LOG_EVENT_UNFILTERED
  -- UNIT_LEVEL
  -- UNIT_FACTION
  -- RAID_TARGET_UPDATE
  -- PLAYER_FOCUS_CHANGED
  -- PLAYER_CONTROL_GAINED
}

local function EnableEvents()
  for i = 1, #EVENTS do
    TidyPlatesThreat:RegisterEvent(EVENTS[i])
  end
end

local function DisableEvents()
  for i = 1, #EVENTS do
    TidyPlatesThreat:UnregisterEvent(EVENTS[i])
  end
end

---------------------------------------------------------------------------------------------------
-- Functions called by TidyPlates
---------------------------------------------------------------------------------------------------

------------------
-- ADDON LOADED --
------------------

StaticPopupDialogs["TidyPlatesEnabled"] = {
  preferredIndex = STATICPOPUP_NUMDIALOGS,
  text = "|cffFFA500" .. t.Meta("title") .. " Warning|r \n---------------------------------------\n" ..
    L["|cff89F559Threat Plates|r is no longer a theme of |cff89F559TidyPlates|r, but a standalone addon that does no longer require TidyPlates. Please disable one of these, otherwise two overlapping nameplates will be shown for units."],
  button1 = OKAY,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  OnAccept = function(self, _, _) end,
}

StaticPopupDialogs["IncompatibleAddon"] = {
  preferredIndex = STATICPOPUP_NUMDIALOGS,
  text = "|cffFFA500" .. t.Meta("title") .. " Warning|r \n---------------------------------------\n" ..
    L["You currently have two nameplate addons enabled: |cff89F559Threat Plates|r and |cff89F559%s|r. Please disable one of these, otherwise two overlapping nameplates will be shown for units."],
  button1 = OKAY,
  button2 = L["Don't Ask Again"],
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  OnAccept = function(self, _, _) end,
  OnCancel = function(self, _, _)
    TidyPlatesThreat.db.profile.CheckForIncompatibleAddons = false
  end,
}

function TidyPlatesThreat:ReloadTheme()
  -- Castbars have to be disabled everytime we login
  if TidyPlatesThreat.db.profile.settings.castbar.show or TidyPlatesThreat.db.profile.settings.castbar.ShowInHeadlineView then
    Addon:EnableCastBars()
  else
    Addon:DisableCastBars()
  end

  -- Recreate all TidyPlates styles for ThreatPlates("normal", "dps", "tank", ...) - required, if theme style settings were changed
  Addon:SetThemes(self)
  Addon:UpdateConfigurationStatusText()
  Addon:InitializeCustomNameplates()
  Addon.Widgets:InitializeAllWidgets()

  -- Update existing nameplates as certain settings may have changed that are not covered by ForceUpdate()
  Addon:UIScaleChanged()

  -- Do this after combat ends, not in PLAYER_ENTERING_WORLD as it won't get set if the player is on combat when
  -- that event fires.
  Addon:CallbackWhenOoC(function() Addon:SetBaseNamePlateSize() end, L["Unable to change a setting while in combat."])
  Addon:CallbackWhenOoC(function()
    local db = self.db.profile
    SetNamePlateFriendlyClickThrough(db.NamePlateFriendlyClickThrough)
    SetNamePlateEnemyClickThrough(db.NamePlateEnemyClickThrough)
  end)

  -- CVars setup for nameplates of occluded units
  if TidyPlatesThreat.db.profile.nameplate.toggle.OccludedUnits then
    Addon:CallbackWhenOoC(function()
      Addon:SetCVarsForOcclusionDetection()
    end)
  end

  for plate, unitid in pairs(Addon.PlatesVisible) do
    Addon:UpdateNameplateStyle(plate, unitid)
  end

  Addon:ForceUpdate()
end

function TidyPlatesThreat:CheckForFirstStartUp()
  local db = self.db.global

  if not self.db.char.welcome then
    self.db.char.welcome = true

    if not Addon.CLASSIC then
      local Welcome = L["|cff89f559Welcome to |r|cff89f559Threat Plates!\nThis is your first time using Threat Plates and you are a(n):\n|r|cff"]..t.HCC[Addon.PlayerClass]..self:SpecName().." "..UnitClass("player").."|r|cff89F559.|r\n"

      -- initialize roles for all available specs (level > 10) or set to default (dps/healing)
      for index=1, GetNumSpecializations() do
        local id, spec_name, description, icon, background, role = GetSpecializationInfo(index)
        self:SetRole(t.SPEC_ROLES[Addon.PlayerClass][index], index)
      end

      t.Print(Welcome..L["|cff89f559You are currently in your "]..self:RoleText()..L["|cff89f559 role.|r"])
      t.Print(L["|cff89f559Additional options can be found by typing |r'/tptp'|cff89F559.|r"])
    end

    local new_version = tostring(t.Meta("version"))
    if db.version ~= "" and db.version ~= new_version then
      -- migrate and/or remove any old DB entries
      t.MigrateDatabase(db.version)
    end
    db.version = new_version
  else
    local new_version = tostring(t.Meta("version"))
    if db.version ~= "" and db.version ~= new_version then
      -- migrate and/or remove any old DB entries
      t.MigrateDatabase(db.version)
    end
    db.version = new_version
  end
end

function TidyPlatesThreat:CheckForIncompatibleAddons()
  -- Check for other active nameplate addons which may create all kinds of errors and doesn't make
  -- sense anyway:
  if TidyPlatesThreat.db.profile.CheckForIncompatibleAddons then
    if IsAddOnLoaded("TidyPlates") then
      StaticPopup_Show("TidyPlatesEnabled", "TidyPlates")
    end
    if IsAddOnLoaded("Kui_Nameplates") then
      StaticPopup_Show("IncompatibleAddon", "KuiNameplates")
    end
    if IsAddOnLoaded("ElvUI") and ElvUI[1] and ElvUI[1].private and ElvUI[1].private.nameplates and ElvUI[1].private.nameplates.enable then
    --if IsAddOnLoaded("ElvUI") and ElvUI[1].private.nameplates.enable then
      StaticPopup_Show("IncompatibleAddon", "ElvUI Nameplates")
    end
    if IsAddOnLoaded("Plater") then
      StaticPopup_Show("IncompatibleAddon", "Plater Nameplates")
    end
    if IsAddOnLoaded("SpartanUI") and SUI.IsModuleEnabled and SUI:IsModuleEnabled("Nameplates") then
      StaticPopup_Show("IncompatibleAddon", "SpartanUI Nameplates")
    end
  end
end

---------------------------------------------------------------------------------------------------
-- AceAddon functions: do init tasks here, like loading the Saved Variables, or setting up slash commands.
---------------------------------------------------------------------------------------------------
-- Copied from ElvUI:
function Addon:SetBaseNamePlateSize()
  local db = TidyPlatesThreat.db.profile.settings

  local width = db.frame.width
  local height = db.frame.height
  if db.frame.SyncWithHealthbar then
    -- this wont taint like NamePlateDriverFrame:SetBaseNamePlateSize

    -- The default size of Threat Plates healthbars is based on large nameplates with these defaults:
    --   NamePlateVerticalScale = 1.7
    --   NamePlateVerticalScale = 1.4
    local zeroBasedScale = 0.7  -- tonumber(GetCVar("NamePlateVerticalScale")) - 1.0
    local horizontalScale = 1.4 -- tonumber(GetCVar("NamePlateVerticalScale"))

    width = (db.healthbar.width - 10) * horizontalScale
    height = (db.healthbar.height + 35) * Lerp(1.0, 1.25, zeroBasedScale)

    db.frame.width = width
    db.frame.height = height
  end

  -- Set to default values if Blizzard nameplates are enabled or in an instance (for friendly players)
  local isInstance, instanceType = IsInInstance()
  isInstance = isInstance and (instanceType == "party" or instanceType == "raid")

  db = TidyPlatesThreat.db.profile
  if Addon.CLASSIC then
    -- Classic has the same nameplate size for friendly and enemy units, so either set both or non at all (= set it to default values)
    if not db.ShowFriendlyBlizzardNameplates and not db.ShowEnemyBlizzardNameplates and not isInstance then
      C_NamePlate.SetNamePlateFriendlySize(width, height)
      C_NamePlate.SetNamePlateEnemySize(width, height)
    else
      -- Smaller nameplates are not available in Classic
      C_NamePlate.SetNamePlateFriendlySize(128, 32)
      C_NamePlate.SetNamePlateEnemySize(128, 32)
    end
  else
    if db.ShowFriendlyBlizzardNameplates or isInstance then
      if NamePlateDriverFrame:IsUsingLargerNamePlateStyle() then
        C_NamePlate.SetNamePlateFriendlySize(154, 64)
      else
        C_NamePlate.SetNamePlateFriendlySize(110, 45)
      end
    else
      C_NamePlate.SetNamePlateFriendlySize(width, height)
    end

    if db.ShowEnemyBlizzardNameplates then
      if NamePlateDriverFrame:IsUsingLargerNamePlateStyle() then
        C_NamePlate.SetNamePlateEnemySize(154, 64)
      else
        C_NamePlate.SetNamePlateEnemySize(110, 45)
      end
    else
      C_NamePlate.SetNamePlateEnemySize(width, height)
    end
  end

  Addon:ConfigClickableArea(false)

  -- For personal nameplate:
  --local clampedZeroBasedScale = Saturate(zeroBasedScale)
  --C_NamePlate_SetNamePlateSelfSize(baseWidth * horizontalScale * Lerp(1.1, 1.0, clampedZeroBasedScale), baseHeight)
end

-- The OnInitialize() method of your addon object is called by AceAddon when the addon is first loaded
-- by the game client. It's a good time to do things like restore saved settings (see the info on
-- AceConfig for more notes about that).
function TidyPlatesThreat:OnInitialize()
  local defaults = t.DEFAULT_SETTINGS

  -- change back defaults old settings if wanted preserved it the user want's to switch back
  if ThreatPlatesDB and ThreatPlatesDB.global and ThreatPlatesDB.global.DefaultsVersion == "CLASSIC" then
    -- copy default settings, so that their original values are
    defaults = t.GetDefaultSettingsV1(defaults)
  end

  local db = LibStub('AceDB-3.0'):New('ThreatPlatesDB', defaults, 'Default')
  self.db = db

  -- Change defaults if deprecated custom nameplates are used (not yet migrated)
  Addon.SetDefaultsForCustomNameplates()

  Addon.LibAceConfigDialog = LibStub("AceConfigDialog-3.0")
  Addon.LibAceConfigRegistry = LibStub("AceConfigRegistry-3.0")
  Addon.LibSharedMedia = LibStub("LibSharedMedia-3.0")
  Addon.LibCustomGlow = LibStub("LibCustomGlow-1.0")

  if Addon.CLASSIC then
    Addon.LibClassicDurations = LibStub("LibClassicDurations")

    Addon.LibClassicCasterino = LibStub("LibClassicCasterino-ThreatPlates")
    --Addon.LibClassicCasterino = LibStub("LibClassicCasterino")
    -- Register callsbacks for spellcasting library
    Addon.LibClassicCasterino.RegisterCallback(self,"UNIT_SPELLCAST_START", Addon.UNIT_SPELLCAST_START)
    Addon.LibClassicCasterino.RegisterCallback(self,"UNIT_SPELLCAST_DELAYED", Addon.UnitSpellcastMidway) -- only for player
    Addon.LibClassicCasterino.RegisterCallback(self,"UNIT_SPELLCAST_STOP", Addon.UNIT_SPELLCAST_STOP)
    Addon.LibClassicCasterino.RegisterCallback(self,"UNIT_SPELLCAST_FAILED", Addon.UNIT_SPELLCAST_STOP)
    Addon.LibClassicCasterino.RegisterCallback(self,"UNIT_SPELLCAST_INTERRUPTED", Addon.UNIT_SPELLCAST_INTERRUPTED)
    Addon.LibClassicCasterino.RegisterCallback(self,"UNIT_SPELLCAST_CHANNEL_START", Addon.UNIT_SPELLCAST_CHANNEL_START)
    Addon.LibClassicCasterino.RegisterCallback(self,"UNIT_SPELLCAST_CHANNEL_UPDATE", Addon.UnitSpellcastMidway) -- only for player
    Addon.LibClassicCasterino.RegisterCallback(self,"UNIT_SPELLCAST_CHANNEL_STOP", Addon.UNIT_SPELLCAST_CHANNEL_STOP)
  end

  Addon.LoadOnDemandLibraries()

  local RegisterCallback = db.RegisterCallback
  RegisterCallback(self, 'OnProfileChanged', 'ProfChange')
  RegisterCallback(self, 'OnProfileCopied', 'ProfChange')
  RegisterCallback(self, 'OnProfileReset', 'ProfChange')

  -- Setup Interface panel options
  local app_name = t.ADDON_NAME
  local dialog_name = app_name .. " Dialog"
  LibStub("AceConfig-3.0"):RegisterOptionsTable(dialog_name, t.GetInterfaceOptionsTable())
  Addon.LibAceConfigDialog:AddToBlizOptions(dialog_name, t.ADDON_NAME)

  -- Setup chat commands
  self:RegisterChatCommand("tptp", "ChatCommand")
end

-- The OnEnable() and OnDisable() methods of your addon object are called by AceAddon when your addon is
-- enabled/disabled by the user. Unlike OnInitialize(), this may occur multiple times without the entire
-- UI being reloaded.
-- AceAddon function: Do more initialization here, that really enables the use of your addon.
-- Register Events, Hook functions, Create Frames, Get information from the game that wasn't available in OnInitialize
function TidyPlatesThreat:OnEnable()
  TidyPlatesThreat:CheckForFirstStartUp()
  TidyPlatesThreat:CheckForIncompatibleAddons()

  if not Addon.CLASSIC then
    Addon.CVars:OverwriteBoolProtected("nameplateResourceOnTarget", self.db.profile.PersonalNameplate.ShowResourceOnTarget)
  end

  Addon.LoadOnDemandLibraries()

  TidyPlatesThreat:ReloadTheme()

  -- Register callbacks at LSM, so that we can refresh everything if additional media is added after TP is loaded
  -- Register this callback after ReloadTheme as media will be updated there anyway
  Addon.LibSharedMedia.RegisterCallback(self, "LibSharedMedia_SetGlobal", "MediaUpdate" )
  Addon.LibSharedMedia.RegisterCallback(self, "LibSharedMedia_Registered", "MediaUpdate" )

  EnableEvents()
end

-- Called when the addon is disabled
function TidyPlatesThreat:OnDisable()
  DisableEvents()

  -- Reset all CVars to its initial values
  -- Addon.CVars:RestoreAllFromProfile()
end

function Addon:CallbackWhenOoC(func, msg)
  if InCombatLockdown() then
    if msg then
      t.Print(msg .. L[" The change will be applied after you leave combat."], true)
    end
    task_queue_ooc[#task_queue_ooc + 1] = func
  else
    func()
  end
end

-- Register callbacks at LSM, so that we can refresh everything if additional media is added after TP is loaded
function TidyPlatesThreat.MediaUpdate(addon_name, name, mediatype, key)
  if mediatype ~= Addon.LibSharedMedia.MediaType.SOUND and not LSMUpdateTimer then
    LSMUpdateTimer = true

    -- Delay the update for one second to avoid firering this several times when multiple media are registered by another addon
    C_Timer_After(1, function()
      LSMUpdateTimer = nil
      -- Basically, ReloadTheme but without CVar and some other stuff
      Addon:SetThemes(TidyPlatesThreat)
      -- no media used: Addon:UpdateConfigurationStatusText()
      -- no media used: Addon:InitializeCustomNameplates()
      Addon.Widgets:InitializeAllWidgets()
      Addon:ForceUpdate()
    end)
  end
end

-----------------------------------------------------------------------------------
-- Functions for keybindings
-----------------------------------------------------------------------------------

function TidyPlatesThreat:ToggleNameplateModeFriendlyUnits()
  local db = TidyPlatesThreat.db.profile

  db.Visibility.FriendlyPlayer.UseHeadlineView = not db.Visibility.FriendlyPlayer.UseHeadlineView
  db.Visibility.FriendlyNPC.UseHeadlineView = not db.Visibility.FriendlyNPC.UseHeadlineView
  db.Visibility.FriendlyTotem.UseHeadlineView = not db.Visibility.FriendlyTotem.UseHeadlineView
  db.Visibility.FriendlyGuardian.UseHeadlineView = not db.Visibility.FriendlyGuardian.UseHeadlineView
  db.Visibility.FriendlyPet.UseHeadlineView = not db.Visibility.FriendlyPet.UseHeadlineView
  db.Visibility.FriendlyMinus.UseHeadlineView = not db.Visibility.FriendlyMinus.UseHeadlineView

  Addon:ForceUpdate()
end

function TidyPlatesThreat:ToggleNameplateModeNeutralUnits()
  local db = TidyPlatesThreat.db.profile

  db.Visibility.NeutralNPC.UseHeadlineView = not db.Visibility.NeutralNPC.UseHeadlineView
  db.Visibility.NeutralMinus.UseHeadlineView = not db.Visibility.NeutralMinus.UseHeadlineView

  Addon:ForceUpdate()
end

function TidyPlatesThreat:ToggleNameplateModeEnemyUnits()
  local db = TidyPlatesThreat.db.profile

  db.Visibility.EnemyPlayer.UseHeadlineView = not db.Visibility.EnemyPlayer.UseHeadlineView
  db.Visibility.EnemyNPC.UseHeadlineView = not db.Visibility.EnemyNPC.UseHeadlineView
  db.Visibility.EnemyTotem.UseHeadlineView = not db.Visibility.EnemyTotem.UseHeadlineView
  db.Visibility.EnemyGuardian.UseHeadlineView = not db.Visibility.EnemyGuardian.UseHeadlineView
  db.Visibility.EnemyPet.UseHeadlineView = not db.Visibility.EnemyPet.UseHeadlineView
  db.Visibility.EnemyMinus.UseHeadlineView = not db.Visibility.EnemyMinus.UseHeadlineView

  Addon:ForceUpdate()
end

-----------------------------------------------------------------------------------
-- WoW EVENTS --
-----------------------------------------------------------------------------------

-- Fired when the player enters the world, reloads the UI, enters/leaves an instance or battleground, or respawns at a graveyard.
-- Also fires any other time the player sees a loading screen
function TidyPlatesThreat:PLAYER_ENTERING_WORLD()
  -- Sync internal settings with Blizzard CVars
  -- SetCVar("ShowClassColorInNameplate", 1)

  local db = self.db.profile.questWidget
  if not Addon.CLASSIC then
    if db.ON or db.ShowInHeadlineView then
      Addon.CVars:Set("showQuestTrackingTooltips", 1)
    else
      Addon.CVars:RestoreFromProfile("showQuestTrackingTooltips")
    end
  end

  db = self.db.profile.Automation
  local isInstance, instance_type = IsInInstance()
  isInstance = isInstance and (instance_type == "party" or instance_type == "raid")

  if isInstance and db.HideFriendlyUnitsInInstances then
    Addon.CVars:Set("nameplateShowFriends", 0)
  else
    -- reset to previous setting
    Addon.CVars:RestoreFromProfile("nameplateShowFriends")
  end

  -- Update custom styles for the current instance
  Addon.UpdateStylesForCurrentInstance()

  -- Adjust clickable area if we are in an instance. Otherwise the scaling of friendly nameplates' healthbars will
  -- be bugged
  Addon:SetBaseNamePlateSize()
end

--function TidyPlatesThreat:PLAYER_LEAVING_WORLD()
--end

function TidyPlatesThreat:PLAYER_LOGIN(...)
  if self.db.char.welcome then
    t.Print(L["|cff89f559Threat Plates:|r Welcome back |cff"]..t.HCC[Addon.PlayerClass]..UnitName("player").."|r!!")
  end
end

--function TidyPlatesThreat:PLAYER_LOGOUT(...)
--end

-- Fires when the player leaves combat status
-- Syncs addon settings with game settings in case changes weren't possible during startup, reload
-- or profile reset because character was in combat.
function TidyPlatesThreat:PLAYER_REGEN_ENABLED()
  -- Execute functions which will fail when executed while in combat
  for i = #task_queue_ooc, 1, -1 do -- add -1 so that an empty list does not result in a Lua error
    task_queue_ooc[i]()
    task_queue_ooc[i] = nil
  end

--  local db = TidyPlatesThreat.db.profile.threat
--  -- Required for threat/aggro detection
--  if db.ON and (GetCVar("threatWarning") ~= 3) then
--    SetCVar("threatWarning", 3)
--  elseif not db.ON and (GetCVar("threatWarning") ~= 0) then
--    SetCVar("threatWarning", 0)
--  end

  local db = TidyPlatesThreat.db.profile.Automation
  local isInstance, _ = IsInInstance()

  -- Dont't use automation for friendly nameplates if in an instance and Hide Friendly Nameplates is enabled
  if db.FriendlyUnits ~= "NONE" and not (isInstance and db.HideFriendlyUnitsInInstances) then
    _G.SetCVar("nameplateShowFriends", (db.FriendlyUnits == "SHOW_COMBAT" and 0) or 1)
  end
  if db.EnemyUnits ~= "NONE" then
    _G.SetCVar("nameplateShowEnemies", (db.EnemyUnits == "SHOW_COMBAT" and 0) or 1)
  end
end

-- Fires when the player enters combat status
function TidyPlatesThreat:PLAYER_REGEN_DISABLED()
  local db = self.db.profile.Automation
  local isInstance, _ = IsInInstance()

  -- Dont't use automation for friendly nameplates if in an instance and Hide Friendly Nameplates is enabled
  if db.FriendlyUnits ~= "NONE" and not (isInstance and db.HideFriendlyUnitsInInstances) then
    _G.SetCVar("nameplateShowFriends", (db.FriendlyUnits == "SHOW_COMBAT" and 1) or 0)
  end  if db.EnemyUnits ~= "NONE" then
    _G.SetCVar("nameplateShowEnemies", (db.EnemyUnits == "SHOW_COMBAT" and 1) or 0)
  end
end