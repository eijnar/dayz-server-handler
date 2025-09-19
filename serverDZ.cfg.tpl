// Template used by dayz-servers.sh to create serverDZ.cfg per instance.
// Edit these defaults to suit your environment. Available placeholders:
//   {{HOSTNAME}}, {{MISSION_TEMPLATE}}, {{DIFFICULTY}}, {{MAP}},
//   {{INSTANCE_NAME}}, {{INSTANCE_ID}}, {{GAME_PORT}},
//   {{STEAM_QUERY_PORT}}, {{STEAM_MASTER_PORT}}
// Game/network ports when rendered: game={{GAME_PORT}}, query={{STEAM_QUERY_PORT}}, master={{STEAM_MASTER_PORT}}

hostname = "{{HOSTNAME}}";
password = "";
passwordAdmin = "adminpass";
enableWhitelist = 0;
whitelistFile = "whitelist.txt";
maxPlayers = 60;
verifySignatures = 2;
forceSameBuild = 1;
forceSameBuildType = 0;
requiredBuild = 0;
disableVoN = 0;
vonCodecQuality = 30;
disable3rdPerson = 1;
disableCrosshair = 1;
lightingConfig = 0;
allowFilePatching = 1;
guaranteedUpdates = 1;
loginQueueConcurrentPlayers = 5;
loginQueueMaxPlayers = 500;
instanceId = {{INSTANCE_ID}};
storageAutoFix = 1;
BattlEye = 1;
serverTime = "SystemTime";
serverTimePersistent = 1;
serverTimeAcceleration = 1;
serverNightTimeAcceleration = 1;
serverTimeOffset = "0000";
serverTimeRandom = 0;
timeStampFormat = "Short";
logAverageFPS = 1;
logMemory = 0;
logPlayers = 1;
logFile = "server_console.log";
enablePlayerDiagLogs = 0;
motd[] = {
  "Welcome to My DayZ Server",
  "Configure motd[] in serverDZ.cfg"
};
motdInterval = 1;

class Missions
{
  class DayZ
  {
    template = "{{MISSION_TEMPLATE}}";
    difficulty = "{{DIFFICULTY}}";
  };
};
