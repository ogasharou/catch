import { generateVapidKeys } from "@mmmike/web-push/vapid";

const keys = await generateVapidKeys();
console.log("");
console.log("VAPID_PUBLIC_KEY=" + keys.publicKey);
console.log("VAPID_PRIVATE_KEY=" + keys.privateKey);
console.log("");
console.log("この2つをCloudflare WorkerのSecretsへ登録してください。");
