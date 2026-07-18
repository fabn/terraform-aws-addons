# Placeholder test: exercises the scaffold (init, provider mock, plan,
# variable validation) so the CI pipeline has something real to run until the
# first addon lands.

mock_provider "aws" {}

run "echoes_name" {
  command = plan

  variables {
    name = "dummy"
  }

  assert {
    condition     = output.name == "dummy"
    error_message = "Placeholder output must echo var.name"
  }
}

run "rejects_empty_name" {
  command = plan

  variables {
    name = ""
  }

  expect_failures = [var.name]
}
