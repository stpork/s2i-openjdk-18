FROM registry.access.redhat.com/redhat-openjdk-18/openjdk18-openshift:latest

COPY run-java.sh /opt/run-java/run-java.sh

USER root

RUN chown -R 1001:1001 /home/jboss
&& chmod 755 1001:1001 /home/jboss

USER 1001
