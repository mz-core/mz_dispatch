local meleeWeapons = {}
for _, weaponName in ipairs({
  'WEAPON_UNARMED', 'WEAPON_KNIFE', 'WEAPON_NIGHTSTICK', 'WEAPON_HAMMER',
  'WEAPON_BAT', 'WEAPON_GOLFCLUB', 'WEAPON_CROWBAR', 'WEAPON_BOTTLE',
  'WEAPON_DAGGER', 'WEAPON_HATCHET', 'WEAPON_KNUCKLE', 'WEAPON_MACHETE',
  'WEAPON_FLASHLIGHT', 'WEAPON_SWITCHBLADE', 'WEAPON_POOLCUE', 'WEAPON_WRENCH',
  'WEAPON_BATTLEAXE', 'WEAPON_STONE_HATCHET'
}) do
  meleeWeapons[GetHashKey(weaponName)] = true
end

AddEventHandler('weaponDamageEvent', function(sender, data)
  local settings = type(MZDispatchConfig.sensors) == 'table' and MZDispatchConfig.sensors or {}
  if settings.enabled ~= true then return end
  sender = tonumber(sender)
  if not sender or sender <= 0 or type(data) ~= 'table' then return end

  local weaponType = tonumber(data.weaponType)
  if not weaponType or weaponType <= 0 then return end
  local categoryCode = meleeWeapons[weaponType] and 'fight' or 'gunshots'
  local response = MZDispatch.Service.recordSensor(sender, categoryCode)
  if response.ok ~= true and response.code ~= 'sensor_cooldown' and response.code ~= 'sensor_busy' then
    print(('[mz_dispatch] sensor signal rejected category=%s code=%s'):format(
      categoryCode, tostring(response.code or 'unknown')
    ))
  end
end)
