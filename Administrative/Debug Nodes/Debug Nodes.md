```
oc get nodes
NAME                 STATUS   ROLES                         AGE   VERSION
ocp113.localdomain   Ready    control-plane,master,worker   13d   v1.35.6
ocp114.localdomain   Ready    control-plane,master,worker   13d   v1.35.6
ocp115.localdomain   Ready    control-plane,master,worker   13d   v1.35.6

oc debug node/ocp113.localdomain
```