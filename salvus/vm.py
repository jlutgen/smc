#!/usr/bin/env python
"""
vm.py -- create and run a virtual machine based on the standard
         salvus_base template with the given memory and vcpus, and add
         the vm to our tinc VPN.  When this script terminates, the vm
         is destroyed, undefined, and the image file associated with
         it is deleted.
"""

#######################################################################
# Copyright (c) William Stein, 2012.  Not open source or free. Will be
# assigned to University of Washington.
#######################################################################

import logging, os, shutil, socket, tempfile, time

from admin import run, sh

conf_path = os.path.join(os.path.split(os.path.realpath(__file__))[0], 'conf')

###########################################
# kvm -- via libvirt
###########################################

def virsh(command, name):
    #return run(['virsh', '--connect', 'qemu:///session', command, name], verbose=False).strip()
    return run(['virsh', '--connect', 'qemu:///system', command, name], verbose=False).strip()

def run_kvm(ip_address, hostname, vcpus, ram, vnc, disk, base, fstab):
    #################################
    # create the copy-on-write image
    #################################
    t = time.time()
    img_path = os.path.join(os.environ['HOME'], 'vm', 'images')
    base_img_path = os.path.join(img_path, 'base')
    if not os.path.exists(base_img_path):
        os.makedirs(base_img_path)
    persistent_img_path = os.path.join(img_path, 'persistent')
    if not os.path.exists(persistent_img_path):
        os.makedirs(persistent_img_path)
    temporary_img_path = os.path.join(img_path, 'temporary')
    if not os.path.exists(temporary_img_path):
        os.makedirs(temporary_img_path)
    new_img = os.path.join(temporary_img_path, hostname + '.img')

    if os.path.exists(new_img):
        raise RuntimeError("the image '%s' already exists; maybe the virtual machine is already running?"%new_img)

    if not base.endswith('.img'): base += '.img'
    base_img = os.path.join(base_img_path, base)
    try:
        #################################
        # create disk images
        #################################
        # Transient image based on our template
        sh['qemu-img', 'create', '-b', base_img, '-f', 'qcow2', new_img]
        log.info("created %s in %s seconds", new_img, time.time()-t); t = time.time()
        # Persistent image(s)
        persistent_images = []
        for name, size, fstype, format in disk:
            persistent_images.append((os.path.join(persistent_img_path, '%s-%s.img'%(hostname, name)), name, fstype, format))
            img = persistent_images[-1][0]
            if not os.path.exists(img):
                os.chdir(persistent_img_path)
                temp = None
                try:
                    # Unfortunately, guestfish doesn't support xfs.
                    sh['qemu-img', 'create', '-f', format, img, '%sG'%size]
                    # See salvus/salvus/scripts/salvus_nbd_format.py
                    if fstype != 'none':
                        log.info("WARNING: formatting filesystem can take a long time...")
                        run(['sudo', '/usr/local/bin/salvus_nbd_format.py', fstype, img], maxtime=1800)
                    sh['chgrp', 'kvm', img]
                    sh['chmod', 'g+rw', img]
                finally:
                    if temp is not None:
                        shutil.rmtree(temp)
                        if os.path.exists('test1.img'):
                            os.unlink('test1.img')
            else:
                pass
                # TODO: else -- if too small, enlarge image if possible

        #################################
        # configure the vm's image
        #################################
        # - mount the image in a temp directory
        tincname = hostname.replace('-','_')
        vmhost_tincname = socket.gethostname().replace('-','_')
        try:
            tmp_path = tempfile.mkdtemp()
            try:
                run(['guestmount', '-i', '-a', new_img, '--rw', tmp_path], maxtime=60)

                #### hostname ####
                hostname_file = os.path.join(tmp_path,'etc/hostname')
                if not os.path.exists(hostname_file):
                    raise RuntimeError("missing /etc/hostname in the VM image; probably the guestmount command is not working, and the fix is probably to type 'sudo chmod a+r /boot/vmlinuz-*'")

                os.unlink(hostname_file)
                open(hostname_file,'w').write(hostname)
                hosts_file = os.path.join(tmp_path, 'etc/hosts')
                hosts = open(hosts_file).read()
                os.unlink(hosts_file)
                open(hosts_file,'w').write("%s\n127.0.1.1  %s\n"%(hosts, hostname))

                #### tinc vpn ####
                tinc_path = os.path.join(tmp_path, 'home/salvus/salvus/salvus/data/local/etc/tinc/')
                open(os.path.join(tinc_path, 'tinc-up'),'w').write(
                    "#!/bin/sh\nifconfig $INTERFACE %s netmask 255.192.0.0"%ip_address)
                open(os.path.join(tinc_path, 'tinc.conf'),'w').write(
                    "Name = %s\nKeyExpire =86400\nConnectTo = %s"%(tincname, vmhost_tincname))
                rsa_key_priv = os.path.join(tinc_path, 'rsa_key.priv')
                rsa_key_pub = os.path.join(tinc_path, 'hosts', tincname)
                if os.path.exists(rsa_key_priv): os.unlink(rsa_key_priv)
                if os.path.exists(rsa_key_pub): os.unlink(rsa_key_pub)
                sh['tincd', '--config', tinc_path, '-K']
                host_file = os.path.join(tinc_path, 'hosts', tincname)
                public_key = open(rsa_key_pub).read().strip()
                open(host_file,'w').write("TCPonly=yes\nCompression=10\nCipher = aes-128-cbc\nSubnet = %s/32\n%s"%(ip_address, public_key))
                # put the tinc public key in our local db, so that the vm can connect to host.
                shutil.copyfile(host_file, os.path.join(conf_path, 'tinc_hosts', tincname))

                #### persisent disks ####
                fstab_file = os.path.join(tmp_path, 'etc/fstab')
                try:
                    f = open(fstab_file,'a')
                    for i,x in enumerate(persistent_images):
                        if x[2] != 'none':   # using defaults instead of nobootwait, since nobootwait causes trouble with firstboot.py
                            f.write("\n/dev/vd%s1   /mnt/%s   %s   defaults  0   2\n"%(chr(98+i),x[1],x[2]))
                            mnt_point = os.path.join(tmp_path, 'mnt/%s'%x[1])
                            os.makedirs(mnt_point)
                    f.write('\n'+fstab+'\n')
                    for x in fstab.splitlines():
                        v = x.split()
                        if not x.lstrip().startswith('#') and len(v) >= 2:
                            mnt_point = os.path.join(tmp_path, v[1].lstrip('/'))
                            os.makedirs(mnt_point)

                finally:
                    f.close()

            finally:
                # - unmount image and remove tmp_path
                sh['fusermount', '-u', tmp_path]
        finally:
            shutil.rmtree(tmp_path)

        log.info("configured image in %s seconds", time.time()-t); t = time.time()

        #################################
        # create and start the vm itself
        #################################
        try:
            cmd = ['virt-install',
                   '--connect', 'qemu:///system',
                   '--cpu', 'host',
                   '--network', 'network:default,model=virtio',
                   '--name', hostname,
                   '--vcpus', vcpus,
                   '--ram', 1024*ram,
                   '--import',
                   '--disk', (new_img + ',device=disk,bus=virtio,format=qcow2,cache=writeback'),
                   '--noautoconsole']

            if vnc:
                cmd.extend(['--graphics', 'vnc,port=%s'%vnc])

            for x in persistent_images:
                cmd.extend(['--disk', '%s,bus=virtio,cache=writeback,format=%s'%(x[0],x[3])])

            os.system("ls -lh %s"%new_img)
            sh['chgrp', 'kvm', new_img]
            sh['chmod', 'g+rw', new_img]
            os.system("ls -lh %s"%new_img)

            log.info(run(cmd, maxtime=120))

            log.info("created new virtual machine in %s seconds -- now running", time.time()-t); t = time.time()

            ##########################################################################
            # - run until vm terminates or we receive term signal, undefined, destroy
            ##########################################################################
            while virsh('domstate', hostname) == 'running':
                 # TODO: this is polling, which violates an axiom.  We absolutely
                 # must rewrite this to be event driven!!!?
                time.sleep(1)
        except Exception, e:
            log.info("error creating virtual machine -- %s"%e)
        finally:
            # clean up
            virsh('undefine', hostname)
            virsh('destroy', hostname)
            pass

    finally:
        try:
            os.unlink(os.path.join(conf_path, 'tinc_hosts', tincname))
        except: pass
        try:
            os.unlink(new_img)
        except: pass

def run_virtualbox(ip_address, hostname, vcpus, ram, vnc, disk, base):
    raise NotImplementedError


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="vm.py starts virtual machine with given IP address and type on this computer")

    parser.add_argument("-d", dest="daemon", default=False, action="store_const", const=True,
                        help="daemon mode (default: False)")
    parser.add_argument("--ip_address", dest="ip_address", type=str, required=True,
                        help="ip address of the virtual machine on the VPN")
    parser.add_argument("--hostname", dest="hostname", type=str, default='',
                        help="hostname of the virtual machine on the VPN")
    parser.add_argument("--vcpus", dest="vcpus", type=str, default="2",
                        help="number of virtual cpus")
    parser.add_argument("--ram", dest="ram", type=int, default=4,
                        help="Gigabytes of ram")
    parser.add_argument("--vnc", dest="vnc", type=int, default=0,
                        help="VNC console port (default: 0 -- no VNC)")
    parser.add_argument("--pidfile", dest="pidfile", type=str, default='',
                        help="store pid in this file")
    parser.add_argument("-l", dest='log_level', type=str, default='INFO',
                        help="log level (default: INFO) useful options include WARNING and DEBUG")
    parser.add_argument("--logfile", dest="logfile", type=str, default='',
                        help="store log in this file (default: '' = don't log to a file)")
    parser.add_argument("--vm_type", dest="vm_type", type=str, default="kvm",
                        help="type of virtual machine to create ('kvm', 'virtualbox')")
    parser.add_argument("--disk", dest="disk", type=str, default="",
                        help="persistent disks: '--disk=cassandra:64:ext4:qcow2,backup:10:xfs:qcow2' makes two sparse qcow2 images of size 64GB and 10GB if they don't exist, one formated ext4 the other xfs, and mounted as /mnt/cassandra and /mnt/backup; if they exist and are smaller than the given size, they are automatically expanded.  The disks are stored as ~/vm/images/ip_address-cassandra.img, etc.  More precisely, the format is --disk=[name]:[size]:[raw|qcow2]:[ext4|xfs|none].  If format is none, then the disk is not mounted in fstab.")
    parser.add_argument("--fstab", dest="fstab", type=str, default="", help="custom string to add to the end of /etc/fstab; each mountpoint in that string will be created if necessary")
    parser.add_argument('--base', dest='base', type=str, default='salvus',
                        help="template image in ~/vm/images/base on which to base this machine; must *not* be running (default: salvus).")

    args = parser.parse_args()

    if args.logfile:
        args.logfile = os.path.abspath(args.logfile)
    if args.pidfile:
        args.pidfile = os.path.abspath(args.pidfile)
    if args.ip_address.count('.') == 0:
        args.ip_address = '10.1.1.' + args.ip_address
    elif args.ip_address.count('.') == 1:
        args.ip_address = '10.1.' + args.ip_address
    elif args.ip_address.count('.') == 2:
        args.ip_address = '10.' + args.ip_address

    assert args.ip_address.startswith('10.'), "ip address must belong to the class A network 10."

    args.hostname = args.hostname if args.hostname else args.ip_address.replace('.','dot')

    try:
        disk = []
        if args.disk:
            for x in args.disk.split(','):
                a = x.split(':')
                if len(a) == 1:
                    a.append('1')
                if len(a) == 2:
                    a.append('ext4')  # default filesystem type
                if len(a) == 3:
                    a.append('raw')
                assert len(a) == 4
                disk.append(a)
    except (IndexError, ValueError):
        raise RuntimeError("--disk option must be of the form 'name1:size1[:fstype][:format],name2:size2[:fstype][:format],...', with size in gigabytes")

    def main():
        global log

        logging.basicConfig()
        log = logging.getLogger('vm')
        log.setLevel(logging.INFO)

        if args.log_level:
            level = getattr(logging, args.log_level.upper())
            log.setLevel(level)

        if args.logfile:
            log.addHandler(logging.FileHandler(args.logfile))

        import admin   # take over the admin logger
        admin.log = log

        log.info("logger started")

        if args.pidfile:
            open(args.pidfile,'w').write(str(os.getpid()))

        if args.vm_type == 'kvm':
            run_kvm(args.ip_address, args.hostname, args.vcpus, args.ram, args.vnc, disk, args.base, fstab=args.fstab)
        elif args.vm_type == 'virtualbox':
            raise NotImplementedError
            run_virtualbox(args.ip_address, args.hostname, args.vcpus, args.ram, args.vnc, disk, args.base)
        else:
            print "Unknown vm_type '%s'"%args.vm_type
            sys.exit(1)

    try:
        if args.daemon:
            import daemon
            daemon.daemonize(args.pidfile)
            main()
        else:
            main()
    finally:
        if args.pidfile and os.path.exists(args.pidfile):
            os.unlink(args.pidfile)
