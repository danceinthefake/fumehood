// One Phoenix Channels connection for the whole app (live audit feed).
// Identity is checked when it connects, the same way as API requests.
import { Socket } from "phoenix";

export const socket = new Socket("/socket");
socket.connect();
