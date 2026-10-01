// Real Cloudflare acceptance must use a normal human browser, not Playwright.
// Automated browser verification remains available only in mocked UI tests.
console.error('AUTOMATED_HUMAN_HARNESS_RETIRED: Open https://www.signalword.app/onboarding/acceptance.html in a normal browser after the matching viewer is deployed. Load the private development fixture locally, complete the human challenge, and save the redacted result. Never paste credentials or CAPTCHA tokens into chat.');
process.exitCode = 1;
