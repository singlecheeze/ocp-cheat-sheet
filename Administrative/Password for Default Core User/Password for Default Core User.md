Ref: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/machine_configuration/machine-configs-configure#core-user-password_machine-configs-configure  
You can use the default core user to access a node through a cloud provider serial console or a bare metal baseboard controller manager (BMC) if a node is down and you cannot access that node by using SSH or the oc debug node command.

By default, Red Hat Enterprise Linux CoreOS (RHCOS) creates a user named core on the nodes in your cluster. However, there is no password for this user. As such, you cannot log in with this user without creating a password by using a machine config. The Machine Config Operator (MCO) assigns the password and injects the password into the /etc/shadow file, allowing you to log in with the core user. The MCO does not examine the password hash. As such, the MCO cannot report if there is a problem with the password.

```bash
[root@rhel9dummy2 dave]# mkpasswd -m SHA-512 Welcome11
$6$/dAWtZhNOiMPG5ms$fBKEHAxjJSWeH/Z1ZLmtABgLR9kUNJopISY.9FOdVJMi.BJh8D9wXu9zEx/93bxQMluJdSEDdkqsLRultbaRX1
```
[Source: `Sources/99-core-password.yaml`](Sources/99-core-password.yaml)
<!-- embed-code: ./Sources/99-core-password.yaml -->
```yaml
```