import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const project = readFileSync('apps/ios/SignalWord.xcodeproj/project.pbxproj', 'utf8');
const setupFlow = readFileSync('apps/ios/SignalWord/Features/AppShell/SignalWordSetupFlow.swift', 'utf8');
const homeView = readFileSync('apps/ios/SignalWord/Features/AppShell/HomeScreen.swift', 'utf8');
const intent = readFileSync('apps/ios/SignalWord/Services/AppIntents/TriggerAlertIntent.swift', 'utf8');
const model = readFileSync('apps/ios/SignalWord/Features/AppShell/AppShellModel.swift', 'utf8');
const session = readFileSync('apps/ios/SignalWord/Services/Auth/SupabaseSessionManager.swift', 'utf8');
const lifecycle = readFileSync('apps/ios/SignalWord/Services/UserAPI/RemoteUserLifecycleAPI.swift', 'utf8');
const credentials = readFileSync('apps/ios/SignalWord/Core/Security/DeviceCredentialStore.swift', 'utf8');
const locationService = readFileSync('apps/ios/SignalWord/Services/Location/LiveLocationService.swift', 'utf8');
const composition = readFileSync('apps/ios/SignalWord/App/AppCompositionRoot.swift', 'utf8');

test('iOS project contains a real application target and App Group entitlement', () => {
  assert.match(project, /productType = "com\.apple\.product-type\.application"/);
  assert.match(project, /CODE_SIGN_ENTITLEMENTS = SignalWord\/SignalWord\.entitlements/);
  assert.match(project, /INFOPLIST_KEY_SignalWordAppGroupIdentifier = group\.com\.signalword\.shared/);
  assert.match(project, /INFOPLIST_KEY_SignalWordSupabaseURL/);
  assert.match(project, /INFOPLIST_KEY_SignalWordUserAPIURL/);
  assert.match(project, /INFOPLIST_KEY_NSFaceIDUsageDescription/);
});

test('iOS location is optional, freshness-bounded, and appended after alert acceptance', () => {
  assert.match(project, /INFOPLIST_KEY_NSLocationWhenInUseUsageDescription/);
  assert.match(locationService, /snapshot\.isUsable\(at: now\)/);
  assert.match(locationService, /requestFreshSnapshot\(timeout:/);
  assert.match(composition, /let outcome = await alertRunner\.trigger/);
  assert.match(composition, /api\.appendLocation/);
  assert.match(composition, /guard let snapshot = await locationService\.requestFreshSnapshot/);
});

test('iOS lifecycle uses refreshable device identity and real authenticated APIs', () => {
  assert.match(session, /InvitedSignIn.requestBody/);
  assert.doesNotMatch(session, /auth\/v1\/signup/);
  assert.match(session, /grant_type.*refresh_token/);
  assert.match(credentials, /refreshToken/);
  assert.match(credentials, /kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly/);
  assert.match(lifecycle, /\/v1\/contacts/);
  assert.match(lifecycle, /\/resolve/);
  assert.match(lifecycle, /\/v1\/data/);
  assert.match(model, /authenticateResolution/);
  assert.match(model, /deleteAccount/);
  assert.doesNotMatch(model, /Resolution is not available until/);
});

test('iOS shell preserves honest safety language and a discoverable real action', () => {
  assert.match(setupFlow, /does not contact police or emergency services/i);
  // Hold completion and early-release cancellation are exercised through XCUITest.
  // Matching a particular SwiftUI modifier cannot establish gesture behavior.
  assert.match(setupFlow, /TEST — NO EMERGENCY/);
  assert.match(homeView, /alert\.trigger/);
  assert.doesNotMatch(setupFlow, /police (?:were|have been) notified/i);
});

test('locked App Intent remains silent and does not open the app', () => {
  assert.match(intent, /static let openAppWhenRun = false/);
  assert.match(intent, /return \.result\(\)/);
  assert.doesNotMatch(intent, /ProvidesDialog|dialog:/);
});
