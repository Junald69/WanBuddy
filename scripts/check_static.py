#!/usr/bin/env python3
"""Sanity checks that do not need a Mac: project.yml, xcconfig, compile flags, secrets."""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
errors = []


def fail(message: str) -> None:
    errors.append(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_dev_login_blocks(source: str) -> str:
    """Remove `#if DEV_LOGIN` ... `#endif` blocks, including nesting."""
    lines = source.splitlines(keepends=True)
    kept = []
    depth = 0
    skipping = 0
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#if"):
            if skipping:
                skipping += 1
                continue
            if re.match(r"#if\s+DEV_LOGIN\b", stripped):
                skipping = 1
                continue
            depth += 1
            kept.append(line)
            continue
        if stripped.startswith("#endif"):
            if skipping:
                skipping -= 1
                continue
            if depth:
                depth -= 1
            kept.append(line)
            continue
        if skipping:
            continue
        kept.append(line)
    return "".join(kept)


project = read(ROOT / "ios" / "project.yml")
for needle in (
    "Debug: debug",
    "Beta: release",
    "Release: release",
    "check_env.sh",
    "supabase-swift",
    "exactVersion: 2.55.6",
    "../Packages/WanBuddyCore",
    "product: WanBuddyCore",
    "product: Supabase",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG DEV_LOGIN",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS: BETA DEV_LOGIN",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS: RELEASE",
):
    if needle not in project:
        fail(f"ios/project.yml is missing {needle!r}")

if "WanBuddyMocks" in project:
    fail("ios/project.yml must not link a separate mocks product")
if re.search(r"com\.junald69\.wanbuddy", project):
    fail("bundle id stem must live only in Common.xcconfig, not project.yml")

gitignore = read(ROOT / ".gitignore")
if "*.xcodeproj" not in gitignore:
    fail(".gitignore must ignore *.xcodeproj")
if list(ROOT.glob("**/*.xcodeproj")):
    fail("an .xcodeproj is present; only project.yml is committed")

common = read(ROOT / "ios" / "Config" / "Common.xcconfig")
if "PRODUCT_BUNDLE_IDENTIFIER_BASE = com.junald69.wanbuddy" not in common:
    fail("Common.xcconfig must set the single bundle id stem")
if "SUPABASE_" in common:
    fail("Common.xcconfig must not contain connection settings")

debug = read(ROOT / "ios" / "Config" / "Debug.xcconfig")
beta = read(ROOT / "ios" / "Config" / "Beta.xcconfig")
release = read(ROOT / "ios" / "Config" / "Release.xcconfig")

dev_ref = "nlvjvmymeuvbxlzikpjx"
publishable = "sb_publishable_rhef8TN72C7vSi6itEHl_g__VXiEkhN"
for label, text, suffix, flags in (
    ("Debug", debug, ".dev", "DEBUG DEV_LOGIN"),
    ("Beta", beta, ".beta", "BETA DEV_LOGIN"),
):
    if '#include "Common.xcconfig"' not in text:
        fail(f"{label}.xcconfig must include Common.xcconfig")
    if f"SUPABASE_PROJECT_REF = {dev_ref}" not in text:
        fail(f"{label}.xcconfig must set the Development ref")
    if "https:/$()/" not in text or dev_ref not in text:
        fail(f"{label}.xcconfig must spell the URL so xcconfig does not treat // as a comment")
    if publishable not in text:
        fail(f"{label}.xcconfig must contain the Development publishable key")
    if f"PRODUCT_BUNDLE_IDENTIFIER = $(PRODUCT_BUNDLE_IDENTIFIER_BASE){suffix}" not in text:
        fail(f"{label}.xcconfig bundle id suffix is wrong")
    if f"SWIFT_ACTIVE_COMPILATION_CONDITIONS = {flags}" not in text:
        fail(f"{label}.xcconfig compile flags must be {flags}")

if '#include "Debug.xcconfig"' in release or '#include "Beta.xcconfig"' in release:
    fail("Release.xcconfig must not include Debug or Beta")
if dev_ref in release or publishable in release:
    fail("Release.xcconfig must not contain Development connection values")
for key in ("SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "SUPABASE_PROJECT_REF"):
    if not re.search(rf"^{key}\s*=\s*$", release, re.M):
        fail(f"Release.xcconfig must leave {key} empty")
if "SWIFT_ACTIVE_COMPILATION_CONDITIONS = RELEASE" not in release:
    fail("Release compile flags must be RELEASE only")
if "DEV_LOGIN" in release or re.search(r"\bDEBUG\b", release):
    fail("Release.xcconfig must not define DEV_LOGIN or DEBUG")

known = read(ROOT / "Packages/WanBuddyCore/Sources/WanBuddyCore/Environment/WanBuddyKnownEnvironment.swift")
shell = read(ROOT / "scripts/check_env.sh")
swift_ref = re.search(r'developmentProjectRef = "([a-z0-9]+)"', known)
shell_ref = re.search(r'^DEV_REF="([a-z0-9]+)"', shell, re.M)
if not swift_ref or not shell_ref or swift_ref.group(1) != dev_ref or shell_ref.group(1) != dev_ref:
    fail("Development ref must match across Swift, check_env.sh, and the spec")

block_file = read(ROOT / "ios/Config/production_refs.blocklist")
block_refs = [
    line.strip()
    for line in block_file.splitlines()
    if line.strip() and not line.strip().startswith("#")
]
array = re.search(r"blockedProductionProjectRefs:\s*\[String\]\s*=\s*\[(.*?)\]", known, re.S)
array_refs = []
if array:
    array_refs = re.findall(r'"([a-z0-9]+)"', array.group(1))
else:
    fail("blockedProductionProjectRefs array is missing")
if array_refs != block_refs:
    fail("production ref blocklist and WanBuddyKnownEnvironment are out of sync")

package_swift = read(ROOT / "Packages/WanBuddyCore/Package.swift")
if '.define("DEV_LOGIN", .when(configuration: .debug))' not in package_swift:
    fail("Package.swift must define DEV_LOGIN only for the debug configuration")
if re.search(r"DEV_LOGIN.*release", package_swift, re.I):
    fail("Package.swift must not define DEV_LOGIN for release")

mock_file = ROOT / "Packages/WanBuddyCore/Sources/WanBuddyCore/Mocks/MockRepositories.swift"
mock_text = read(mock_file)
if not mock_text.lstrip().startswith("#if DEV_LOGIN"):
    fail("mock repositories must be wrapped in #if DEV_LOGIN")
if "MockAuthRepository" not in mock_text:
    fail("MockAuthRepository is missing")

dev_dir = ROOT / "ios/WanBuddy/Dev"
dev_files = list(dev_dir.glob("*.swift"))
if not dev_files:
    fail("ios/WanBuddy/Dev is empty")
for path in dev_files:
    text = read(path).lstrip()
    if not text.startswith("#if DEV_LOGIN"):
        fail(f"{path.relative_to(ROOT)} must start with #if DEV_LOGIN")
    if not text.rstrip().endswith("#endif"):
        fail(f"{path.relative_to(ROOT)} must end with #endif")

forbidden_outside_dev_login = (
    "DevLoginView",
    "signInWithEmail",
    "signIn(email",
    "MockAuthRepository",
    "MockProfileRepository",
    "MockFriendRepository",
    "MockPresenceRepository",
    "MockSafetyRepository",
)
app_root = ROOT / "ios/WanBuddy"
for path in app_root.rglob("*.swift"):
    visible = strip_dev_login_blocks(read(path))
    # DEBUG-only preview smoke tests may name mock types. Strip those too.
    visible = re.sub(r"(?ms)^\s*#if DEBUG\b.*?^\s*#endif\s*$", "", visible)
    for token in forbidden_outside_dev_login:
        if token in visible:
            fail(f"{token} is visible outside #if DEV_LOGIN in {path.relative_to(ROOT)}")

for path in (ROOT / "Packages/WanBuddyCore/Sources").rglob("*.swift"):
    text = read(path)
    if "??" in text and "Config" in str(path):
        fail(f"{path.relative_to(ROOT)} uses ?? while loading configuration")
    if "https://nlvjvmymeuvbxlzikpjx" in text:
        fail(f"{path.relative_to(ROOT)} hardcodes the Development URL")
    if dev_ref in text and path.name != "WanBuddyKnownEnvironment.swift":
        fail(f"Development ref leaked into {path.relative_to(ROOT)}")

bootstrap = read(ROOT / "ios/WanBuddy/App/ConfigBootstrap.swift")
if "??" in bootstrap:
    fail("ConfigBootstrap must not use ?? defaults")
if dev_ref in bootstrap or "https://" in bootstrap:
    fail("ConfigBootstrap must not embed a connection default")

secret_tokens = ("service_role", "sb_secret_")
allowed_secret_mentions = {
    ROOT / "scripts/check_env.sh",
    ROOT / "scripts/test_check_env.sh",
    ROOT / "scripts/check_static.py",
    ROOT / "Packages/WanBuddyCore/Sources/WanBuddyCore/Config/ConfigValidator.swift",
    ROOT / "Packages/WanBuddyCore/Tests/WanBuddyCoreTests/WanBuddyCoreTests.swift",
}
for path in ROOT.rglob("*"):
    if not path.is_file():
        continue
    if any(part in {".git", ".build"} for part in path.parts):
        continue
    if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".zip"}:
        continue
    if path.resolve() in allowed_secret_mentions:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for token in secret_tokens:
        if token in text:
            fail(f"{token} appears in {path.relative_to(ROOT)}")

linux = read(ROOT / ".github/workflows/linux.yml")
ios = read(ROOT / ".github/workflows/ios.yml")
if "pull_request:" not in linux or "push:" not in linux:
    fail("Linux workflow must run on pull_request and push")
if "workflow_dispatch:" not in ios:
    fail("iOS workflow must be workflow_dispatch")
for banned in ("pull_request:", "push:"):
    if banned in ios:
        fail(f"iOS workflow must not trigger on {banned}")
if "macos-" not in ios:
    fail("iOS workflow must use a macOS runner")
if "contents: read" not in linux or "contents: read" not in ios:
    fail("workflows must set permissions: contents: read")

if errors:
    print("static checks failed:")
    for message in errors:
        print(f"  - {message}")
    sys.exit(1)

print("static checks passed")
