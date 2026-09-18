```text
htpasswd -c -B -b users.htpasswd dave Welcome11
htpasswd -B -b users.htpasswd anotherperson 'somepassword'
```  
Upload `users.htpasswd` file as new identity provider HTPasswd
```text
[dave@rhel9dummy2 ~]$ cat users.htpasswd
dave:$2y$05$/vakuBwZjuls8XB/s4L91.LMbR.xwNKDV5Mi/BLoLkXWBV40oXpTq
```
Once applied (Takes a minute), login to the web UI with the user you just added (Required)  
Then with `oc` apply cluster admin to new user `dave`  
```
oc login https://api.ocp4.localdomain:6443 -u kubeadmin
oc adm policy add-cluster-role-to-user cluster-admin dave
oc login https://api.ocp4.localdomain:6443 -u dave
```