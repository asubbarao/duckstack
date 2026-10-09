# Quack reload transition

Reloading now belongs to the SQL watcher registered by `server/cron.sql`. After
this PR merges, boot out the obsolete `com.inframe.quack-reload` launchd agent
if it is still installed; do not bootstrap a replacement plist.
