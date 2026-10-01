# SignalWord contact viewer

The viewer is a mobile-first React and Vite application. It renders scoped event projections and provides the explicit trusted-contact confirmation screen. Confirmation is a user-initiated POST so email link scanners cannot consume a single-use token merely by opening the URL.

It must never persist a viewer or confirmation token in analytics, browser storage, logs, or query parameters. Both capabilities stay in path segments and pass through bounded same-origin server proxies. Run it locally with `npm run dev --workspace=@signalword/viewer`; build and tests run through the repository’s `npm run verify` command.
