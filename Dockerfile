FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive

# Install base dependencies
RUN apt-get update && apt-get install -y \
    openssh-server sudo wget curl vim net-tools iputils-ping \
    software-properties-common ssh rsync && \
    rm -rf /var/lib/apt/lists/*

# Create hadoop user
RUN groupadd hadoop && \
    useradd -ms /bin/bash -g hadoop hduser && \
    echo 'hduser:hduser' | chpasswd && \
    adduser hduser sudo && \
    mkdir -p /var/run/sshd

# Configure SSH
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Copy setup script
COPY run.sh /setup-hadoop.sh
RUN chmod +x /setup-hadoop.sh

# Expose ports
EXPOSE 22 9870 9864 8042 8088 9000

CMD ["/bin/bash", "-c", "/setup-hadoop.sh && /usr/sbin/sshd -D"]