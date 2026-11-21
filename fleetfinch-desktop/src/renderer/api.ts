import { createApiClient } from "@fleetfinch/shared";

import { env } from "@/env.ts";

export const api = createApiClient(
  (path) => new URL(path, env.VITE_API_BASE_URL),
);
