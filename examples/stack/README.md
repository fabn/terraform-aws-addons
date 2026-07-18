# Stack example

The formation-style usage: one `addons` map with Heroku-like sizes, merged
`env` / `sensitive_env` outputs that plug straight into the
[fabn/formation/kubernetes](https://registry.terraform.io/modules/fabn/formation/kubernetes)
module.

```bash
terraform init
terraform plan -var vpc_id=vpc-xxx -var 'subnet_ids=["subnet-a","subnet-b"]'
```
