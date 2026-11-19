// Setup of the frontend tests (vite.config.ts → test.setupFiles).

import "@testing-library/jest-dom/vitest";

import { clearMocks } from "@tauri-apps/api/mocks";
import { cleanup, configure } from "@testing-library/react";
import { afterEach } from "vitest";

import { installDialog } from "./dialog";

installDialog();

// The application renders in <React.StrictMode> (src/main.tsx), so do the tests.
configure({ reactStrictMode: true });

afterEach(() => {
  // Unmount first: the components unsubscribe from events through the IPC mock.
  cleanup();
  clearMocks();
});
