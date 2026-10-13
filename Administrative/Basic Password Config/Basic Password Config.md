#### How to generate a HTPasswd file for the HTPasswd OAuth Provider
```bash
htpasswd -c -B -b users.htpasswd dave Welcome11
htpasswd -B -b users.htpasswd anotherperson 'somepassword'
```  
Upload `users.htpasswd` file as new identity provider HTPasswd (Or just copy the contents of the file)
```bash
[dave@rhel9dummy2 ~]$ cat users.htpasswd
dave:$2y$05$/vakuBwZjuls8XB/s4L91.LMbR.xwNKDV5Mi/BLoLkXWBV40oXpTq
```
Once applied (Takes a minute), login to the web UI with the user you just added (Required)  
Then with `oc` apply cluster admin to new user `dave`  
```bash
oc login https://api.ocp4.localdomain:6443 -u kubeadmin
oc adm policy add-cluster-role-to-user cluster-admin dave
oc login https://api.ocp4.localdomain:6443 -u dave
```
#### How to get your username and a token
```bash
oc whoami
dave

oc whoami -t
sha256~dznLnDdoTZRylAeoy3gVeKSbRKa2avy7j2siQ66PFwc
```