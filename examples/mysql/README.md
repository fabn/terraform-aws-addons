# Standalone MySQL example

A single addon submodule used directly (no root wrapper), with a custom
Serverless v2 capacity range instead of a preset size — the escape hatch for
requirements the `mini`/`small`/`medium`/`large` presets don't cover.

```bash
terraform init
terraform plan -var vpc_id=vpc-xxx -var 'subnet_ids=["subnet-a","subnet-b"]'
```
