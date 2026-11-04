fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mz_dispatch'
author 'Mazus'
description 'Owner server-side de chamados compartilhados entre servicos MZ'
version '1.0.0'

shared_script 'config.lua'

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/bridge.lua',
  'server/repository.lua',
  'server/prepare.lua',
  'server/service.lua',
  'server/sensors.lua',
  'server/events.lua'
}

client_script 'client/main.lua'

dependencies {
  'oxmysql',
  'mz_core',
  'mz_org',
  'mz_menu'
}

ui_page 'web/index.html'

files {
  'web/index.html',
  'web/dispatch.css',
  'web/dispatch.js'
}
