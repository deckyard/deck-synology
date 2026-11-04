<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Virtual machines

The `SYNO.Virtualization.API.*` verbs drive Virtual Machine Manager, as
Synology's Virtual Machine Manager API guide describes it. The account needs
to administer VMM. A virtual machine, image, storage or network is named by
its name, as in the VMM interface.

## What is there

```jennifer
for (def h in synology.vmHosts($c)) {
    io.printf("%s: %d of %d CPU threads free, %d MiB RAM free\n", $h.name, $h.freeCpus, $h.totalCpus, $h.freeRamMb);
}
for (def g in synology.guests($c)) {
    io.printf("%s %s %d vCPU %d MiB\n", $g.name, $g.status, $g.vcpus, $g.ramMb);
}
```

`vmStorages`, `vmNetworks` and `vmImages` list where a machine can go, what
it can connect to and what it can be made from.

## Deploying a virtual machine

```jennifer
synology.createImage($c, "debian-12", "disk", "/vm/debian-12.qcow2", ["Synology - VM Storage 1"]);

def spec as synology.GuestSpec init synology.GuestSpec{
    name: "web01",
    storage: "Synology - VM Storage 1",
    disks: [synology.DiskSpec{sizeMb: 0, image: "debian-12"}, synology.DiskSpec{sizeMb: 20480, image: ""}],
    networks: ["Default VM Network"],
    vcpus: 2,
    ramMb: 2048
};
def web as synology.Guest init synology.createGuest($c, $spec);
synology.powerOnGuest($c, $web.name);
```

`createImage` imports a file already on the NAS (upload it with `upload`
first) and waits until VMM is done. `createGuest` copies the image into the
first disk, creates the empty one, waits for the task, and then sets CPUs
and memory: VMM's `create` takes neither. The machine stays off.

## Running it

```jennifer
synology.shutdownGuest($c, "web01");    # through the guest OS, like the power button
synology.powerOffGuest($c, "web01");    # cut the power
synology.resizeGuest($c, "web01", 4, 0);
synology.setAutorun($c, "web01", "on");
synology.deleteGuest($c, "web01");
```

`shutdownGuest` returns once VMM has asked; poll `guest` for `shutdown` before
changing what needs the machine off. Powering on fails with code 902 or 903
when the host lacks CPU threads or memory, and deleting a running machine
with 904.
