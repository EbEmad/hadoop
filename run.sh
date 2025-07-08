#!/bin/bash
set -e

echo "=== Setting Up Hadoop Cluster ==="

# Update system
echo "Updating system packages..."
apt-get update && apt-get upgrade -y

# Install Java 8 and dependencies
echo "Installing Java 8 and dependencies..."
apt-get install -y --no-install-recommends \
    openjdk-8-jdk \
    ssh \
    pdsh \
    openssh-client \
    net-tools \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Set Java environment
echo "Configuring Java environment..."
cat <<EOF >> /home/hduser/.bashrc
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

# Install Hadoop
echo "Setting up Hadoop..."
cd /usr/local
if [ ! -d "hadoop" ]; then
    echo "Downloading Hadoop..."
    if ! wget -q https://archive.apache.org/dist/hadoop/common/hadoop-3.3.6/hadoop-3.3.6.tar.gz; then
        echo "Failed to download Hadoop"
        exit 1
    fi
    
    echo "Extracting Hadoop..."
    if ! tar -xzf hadoop-3.3.6.tar.gz; then
        echo "Failed to extract Hadoop"
        exit 1
    fi
    
    echo "Setting up Hadoop directory..."
    mv hadoop-3.3.6 hadoop
    rm hadoop-3.3.6.tar.gz
    
    echo "Setting permissions..."
    chown -R hduser:hadoop hadoop
    find hadoop -type d -exec chmod 755 {} \;
    find hadoop -type f -exec chmod 644 {} \;
    chmod -R 755 hadoop/bin hadoop/sbin
    
    echo "Hadoop extracted and configured successfully"
else
    echo "Hadoop directory already exists, skipping extraction"
fi

# Configure SSH for passwordless login
echo "Configuring SSH..."
mkdir -p /var/run/sshd
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config
echo "UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config

service ssh restart

su - hduser -c "
    mkdir -p ~/.ssh
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -f ~/.ssh/id_rsa -q -N ''
    fi
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    echo \"SSH configured for hduser\"
"

# Set Hadoop environment
echo "Configuring Hadoop environment..."
cat <<EOF >> /home/hduser/.bashrc
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin
export HADOOP_OPTS="-Djava.library.path=\$HADOOP_HOME/lib/native"
export PDSH_RCMD_TYPE=ssh
export HADOOP_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

# Configure Hadoop core settings with container optimizations
echo "Configuring Hadoop core settings..."
cat > /usr/local/hadoop/etc/hadoop/hadoop-env.sh <<EOF
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export HADOOP_NICENESS=0
export HDFS_NAMENODE_USER="hduser"
export HDFS_DATANODE_USER="hduser"
export HDFS_SECONDARYNAMENODE_USER="hduser"
export YARN_RESOURCEMANAGER_USER="hduser"
export YARN_NODEMANAGER_USER="hduser"
export HADOOP_HEAPSIZE_MAX=512m
export HADOOP_OPTS="\$HADOOP_OPTS -Xmx512m -XX:+UseContainerSupport"
EOF

# Configure core-site.xml
cat > /usr/local/hadoop/etc/hadoop/core-site.xml <<EOF
<configuration>
    <property>
        <name>hadoop.tmp.dir</name>
        <value>/app/hadoop/tmp</value>
    </property>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://$(hostname):9000</value>
    </property>
    <property>
        <name>hadoop.proxyuser.hduser.hosts</name>
        <value>*</value>
    </property>
    <property>
        <name>hadoop.proxyuser.hduser.groups</name>
        <value>*</value>
    </property>
</configuration>
EOF

# Configure hdfs-site.xml
cat > /usr/local/hadoop/etc/hadoop/hdfs-site.xml <<EOF
<configuration>
    <property>
        <name>dfs.replication</name>
        <value>1</value>
    </property>
    <property>
        <name>dfs.namenode.name.dir</name>
        <value>file:///usr/local/hadoop/yarn_data/hdfs/namenode</value>
    </property>
    <property>
        <name>dfs.datanode.data.dir</name>
        <value>file:///usr/local/hadoop/yarn_data/hdfs/datanode</value>
    </property>
    <property>
        <name>dfs.permissions.enabled</name>
        <value>false</value>
    </property>
    <property>
        <name>dfs.client.use.datanode.hostname</name>
        <value>true</value>
    </property>
</configuration>
EOF

# Configure yarn-site.xml
cat > /usr/local/hadoop/etc/hadoop/yarn-site.xml <<EOF
<configuration>
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>
    <property>
        <name>yarn.nodemanager.aux-services.mapreduce.shuffle.class</name>
        <value>org.apache.hadoop.mapred.ShuffleHandler</value>
    </property>
    <property>
        <name>yarn.resourcemanager.hostname</name>
        <value>$(hostname)</value>
    </property>
</configuration>
EOF

# Create HDFS directories with proper permissions
echo "Creating HDFS directories..."
mkdir -p /app/hadoop/tmp /usr/local/hadoop/yarn_data/hdfs/{namenode,datanode}
chown -R hduser:hadoop /app/hadoop /usr/local/hadoop/yarn_data
chmod -R 755 /app/hadoop /usr/local/hadoop/yarn_data

# Clean any existing data
echo "Cleaning existing HDFS data..."
rm -rf /usr/local/hadoop/yarn_data/hdfs/* /app/hadoop/tmp/* /tmp/hadoop*

# Format HDFS
echo "Formatting HDFS..."
su - hduser -c "
    source ~/.bashrc
    /usr/local/hadoop/bin/hdfs namenode -format -force
    if [ \$? -ne 0 ]; then
        echo 'HDFS formatting failed'
        exit 1
    fi
    echo 'HDFS formatted successfully'
"

# Create startup script with direct daemon start
cat > /start-hadoop.sh <<'EOF'
#!/bin/bash
source /home/hduser/.bashrc

# Start SSH first
service ssh start

# Start Hadoop services directly (bypassing PDSH issues)
echo "Starting Hadoop services directly..."
/usr/local/hadoop/bin/hdfs --daemon start namenode
/usr/local/hadoop/bin/hdfs --daemon start datanode
/usr/local/hadoop/bin/hdfs --daemon start secondarynamenode
/usr/local/hadoop/bin/yarn --daemon start resourcemanager
/usr/local/hadoop/bin/yarn --daemon start nodemanager

# Verify services
echo "Running Java processes:"
jps

# Keep container running
tail -f /dev/null
EOF
chmod +x /start-hadoop.sh

# Start services and keep container running
echo "=== Starting Hadoop Services ==="
exec /start-hadoop.sh