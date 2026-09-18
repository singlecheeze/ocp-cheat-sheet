Ref: https://github.com/openshift/installer/blob/main/docs/user/metal/install_ipi.md  
Ref: https://access.redhat.com/solutions/7135358  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ This might differ slightly by server manufacturer even though it's supposed to be a consistent spec for OEMs...  
  
To test redfish endpoint: https://172.16.1.14/redfish/v1/Systems/Self  
  
<img width="808" height="661" alt="image" src="https://gist.github.com/user-attachments/assets/95ca095b-a96f-4783-acdf-775a3c1e2136" />
  
```text
redfish-virtualmedia://172.16.1.13/redfish/v1/Systems/Self
```
  
<img width="789" height="1065" alt="image" src="https://gist.github.com/user-attachments/assets/6411a5ed-1ba6-464c-b134-e2a3de1a2763" />
