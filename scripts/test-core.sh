#!/bin/sh
# Run the checked-in XCTest scenarios with Swift assertions when CLT lacks XCTest.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/tabwm-core-tests.XXXXXX")
trap 'rm -rf "$run_dir"' EXIT HUP INT TERM
python3 - "$project_dir" "$run_dir" <<'PY'
from pathlib import Path
import re, sys
root, output = map(Path, sys.argv[1:])
source = (root / 'Tests/TabWMCoreTests/GroupEngineTests.swift').read_text()
source = source.replace('import XCTest\n@testable import TabWMCore', 'import Foundation\nimport CoreGraphics')
source = source.replace('final class GroupEngineTests: XCTestCase', 'final class GroupEngineTests')
methods = re.findall(r'    func (test\w+)\(\)( throws)?', source)
assert methods, 'No test methods found'
source += '''
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, "Expected true", file: file, line: line) }
func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(!value, "Expected false", file: file, line: line) }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { precondition(value == nil, "Expected nil", file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Values differ: \\(a) and \\(b)", file: file, line: line) }
@main struct CoreTestRunner {
 static func main() throws {
 let tests = GroupEngineTests()
'''
for name, throwing in methods:
    source += f' {"try " if throwing else ""}tests.{name}()\n print("PASS: {name}")\n'
source += f' print("Passed {len(methods)} core scenarios")\n }}\n}}\n'
(output / 'Runner.swift').write_text(source)
PY
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/tabwm-core-module-cache" "$project_dir"/Sources/TabWMCore/*.swift "$run_dir/Runner.swift" -o "$run_dir/runner"
"$run_dir/runner"
