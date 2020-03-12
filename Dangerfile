# Warn when there is a big PR
warn("Big PR") if git.lines_of_code > 1000

xcov.report(
  workspace: 'RInAppMessaging.xcworkspace',
  scheme: 'RInAppMessaging-Example',
  output_directory: 'artifacts/unit-tests/coverage',
  source_directory: 'RInAppMessaging',
  json_report: true,
  include_targets: 'RInAppMessaging.framework',
  include_test_targets: false
# FIXME: add `minimum_coverage_percentage: 70.0` once SDKCF-1880 is merged
)
