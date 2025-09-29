# 安装 safe-rm
sudo bash safe-rm.sh install

# 删除文件（默认进入回收站，保留目录结构）
rm test.txt

# 真删除
rm --purge test.txt

# 清理回收站7天以上文件
rm --clean

# 交互式恢复
rm restore
# 输入索引 / all / keyword:<关键字> / dir:<目录路径>

# 卸载 safe-rm
sudo bash safe-rm.sh uninstall
