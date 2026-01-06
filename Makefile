# SPDX-License-Identifier: GPL-2.0
#
# Makefile for PCI Hardware Error Handling Module
#

obj-m := enyx_hfp_pci.o
enyx_hfp_pci-objs := pci_error_handling.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

.PHONY: all clean install
