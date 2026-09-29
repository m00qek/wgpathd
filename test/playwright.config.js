const { defineConfig, devices } = require('@playwright/test');

// Run by `make browser` in the browser container, which shares only the loopback of
// the LuCI container: uhttpd listens on 127.0.0.1:80 there.
module.exports = defineConfig({
  testDir: './tests',
  outputDir: './results/artifacts',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 30000,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1',
    // A browser zone unlike the router's (UTC) proves clock times follow the router.
    locale: 'en-GB',
    timezoneId: 'America/New_York',
    screenshot: 'only-on-failure',
    actionTimeout: 5000,
    navigationTimeout: 10000,
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: {
          executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
          args: ['--no-sandbox', '--disable-setuid-sandbox'],
        },
      },
    },
  ],
});
