查看是否已安装
rpm -qa firewalld
 
没安装的话，安装
yum install firewalld firewall-config
 
启动
sudo systemctl start firewalld
sudo systemctl enable firewalld
sudo systemctl status firewalld