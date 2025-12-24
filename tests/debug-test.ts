import { spawn } from "bun";
import {
  RTACH_BIN,
  uniqueSocketPath,
  cleanupSocket,
  startDetachedMaster,
  connectClient,
  waitForOutput,
  writeToProc,
  killAndWait,
} from "./helpers";

async function main() {
  const socketPath = uniqueSocketPath();
  console.log("Starting master...");
  const master = await startDetachedMaster(socketPath, "/bin/cat");
  console.log("Master started");

  console.log("Connecting client...");
  const client = connectClient(socketPath, { noDetachChar: true });
  
  const message = "X".repeat(64);
  
  for (let i = 0; i < 30; i++) {
    const marker = `L${i}`;
    console.log(`Writing ${marker}...`);
    await writeToProc(client, marker + message.slice(marker.length));
    console.log(`Waiting for ${marker}...`);
    try {
      await waitForOutput(client, marker, 1000);
      console.log(`Got ${marker}`);
    } catch (e) {
      console.log(`FAILED at ${marker}:`, e);
      break;
    }
  }

  client.kill(9);
  await client.exited;
  await killAndWait(master, 9);
  cleanupSocket(socketPath);
}

main().catch(console.error);
