# SF Visualizer — Development Notes

## User Context
The developer is new to terminal/CLI workflows. Always provide full copy-paste commands when pushing updates.

## After Pushing Changes
When changes are pushed, ALWAYS provide the full command sequence to pull and restart:

```
cd ~/sf-visualizer
git pull
```

Terminal 1 (backend):
```
cd ~/sf-visualizer/server
npx tsx watch src/index.ts
```

Terminal 2 (frontend):
```
cd ~/sf-visualizer/client
npx vite
```

Then refresh the browser at http://localhost:5173

## Environment Variables
When the user needs to edit `.env`, tell them to run:
```
open -a TextEdit ~/sf-visualizer/.env
```
Then save with Cmd+S.

## Stopping Servers
Remind the user to press `Ctrl+C` in each terminal window before restarting.
