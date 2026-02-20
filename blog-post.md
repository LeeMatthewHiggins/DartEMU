# Building DartEMU: A RISC-V System Emulator in Dart

How I built a virtual computer in Dart that boots Linux — and got it running in a browser.

## What Is This?

DartEMU is a software-based computer. It pretends to be a RISC-V processor — reading instructions, managing memory, handling interrupts — well enough that a real Linux kernel boots on top of it and has no idea it's not running on actual hardware. You get a terminal, a filesystem, networking, the works. And it all runs inside a Flutter app.

The whole thing is written in Dart. No C, no native code, no foreign function calls. Just Dart, compiled to whatever platform you're targeting: phones, desktops, or a web browser.

## Why RISC-V?

If you're going to simulate a processor, you need a blueprint. Most processor designs are proprietary — x86 (the architecture behind Intel and AMD chips) is buried under decades of licensing and complexity. Arm, which powers most phones, requires fees to use. Their documentation is extensive but gatekept.

RISC-V is the open-source alternative. The entire specification is freely published, clearly written, and designed to be simple. The base instruction set has around 40 instructions — compare that to the thousands in x86. Features are added through optional extensions: one for multiplication, one for atomic operations, one for floating-point maths, and so on. Each extension is a self-contained chapter in the spec.

This modularity is what makes RISC-V ideal for a project like this. You can start with the bare minimum — read an instruction, decode it, execute it — and gradually add capabilities until Linux boots. The spec tells you exactly what each instruction should do and what should happen when something goes wrong. There are no hidden behaviours to reverse-engineer. It's an architecture designed to be implemented, not just used.

## Why Dart?

For years I've been setting myself the same challenge: find something Dart supposedly can't do, then make it do it. Real-time DSP. Software rendering. Low-level bit manipulation that "needs" C. Each project starts with the assumption that Dart will hit a wall, and the interesting part is finding out exactly where that wall is — or whether it exists at all.

The most public of these was [porting DOOM to pure Dart](https://www.weareaifirst.com/blog/will-dart-run-doom) — every rendering algorithm reimplemented from scratch, no native code, Flutter as nothing more than a display surface. That one proved Dart could handle real-time graphics at decent frame rate. It also surfaced the first signs of JavaScript's number limitations on the web, a theme that would come back to haunt this project.

DartEMU is a different kind of challenge entirely. We're used to seeing Flutter produce graphical output — that's its comfort zone. A system emulator is something else. There's no UI to render, no widgets to compose. It's simulating an entire computer under the hood: CPU, memory, storage, networking, all running continuously and all needing to be bit-exact. It's low-level systems programming, and that's not territory anyone associates with Dart.

But Dart has something C doesn't: Flutter. If the emulator is a pure Dart package, it can be embedded in any Flutter app as a widget — and that means it runs on iOS, Android, macOS, Linux, Windows, and the web from a single codebase. That's a deployment story worth chasing. This is DART and Flutters superpower. 

While researching a starting point, I came across [TinyEMU](https://bellard.org/tinyemu/) — a compact but complete RISC-V emulator written in C. It boots Linux, supports virtual devices, and fits in a few thousand lines. Then I looked up the author, Fabrice Bellard, and fell down a rabbit hole. This is the person who created FFmpeg, QEMU, the Tiny C Compiler, and once held the world record for computing the most digits of pi. One of those names you stumble across and realise has been quietly behind half the tools you've used for decades. TinyEMU turned out to be an excellent reference implementation to port from.

The whole project came together over about five days.

## Day 1: The Initial Port

The first commit landed a working 64-bit RISC-V emulator with support for the core instruction set plus several extensions (multiply/divide, atomic operations, compressed instructions). It could boot a Linux kernel through a bootloader and drop into a console.

An emulator isn't just a CPU loop — it also needs to fake all the hardware that an operating system expects. That means a memory management unit (which translates virtual addresses to physical ones, just like real hardware does for process isolation), interrupt controllers (which tell the CPU when devices need attention), timers, and a virtual I/O system so the guest OS can talk to a console. All of this was in the initial port.

By the end of the day, the emulator could boot Linux and drop into a shell. But there was no filesystem, no floating-point maths, and the whole thing was tied to the command line.

## Day 2: Making It Real

This was the most intense day. Six big commits landed, each solving a different layer of the problem.

**Storage and floating point** came first. The emulator gained a virtual hard drive (so Linux could mount a root filesystem) and a complete floating-point implementation — both single and double precision — using software-based arithmetic. Linux could now boot all the way to a login prompt.

Then came a wave of **correctness fixes**. An emulator has to match real hardware behaviour exactly, or the operating system will crash in subtle ways. Instructions that span a page boundary. Exception handling for privileged operations. Timer interrupts based on wall-clock time instead of instruction count (without this, commands like `sleep` would hang forever because the emulator's internal clock only advanced when it was actively running instructions).

The most important change was **decoupling the emulator from the command line**. Instead of reading directly from stdin and writing to stdout, the emulator was refactored to use Dart streams for all its I/O. This is what made it possible to embed it in a Flutter app — the terminal widget could subscribe to the same output stream and pipe keyboard input back in.

## Day 2 (cont): Flutter and the Web

The Flutter example app landed the same evening — a terminal widget that embedded the emulator and let you interact with the guest Linux system directly on screen. The core library was split into platform-independent and platform-specific parts so it could compile for the web.

Getting it working surfaced a couple of Flutter-specific issues: asset data loaded from the app bundle is read-only, but the guest OS needs to write to its virtual hard drive, so the data had to be copied into writable memory first. And the stream plumbing needed careful wiring so that the terminal would receive output even if it connected before the emulator started booting.

## Day 3: The JavaScript Problem

This is where things got interesting.

### Why 64-bit Can't Work on the Web

To understand this problem, you need a small piece of JavaScript history.

When Brendan Eich designed JavaScript in 1995, he made a deliberate choice: there would be one number type. No integers, no floats, no signed vs unsigned — just `number`. Under the hood, every number in JavaScript is a 64-bit IEEE 754 double-precision floating-point value. The same format your CPU uses for decimal maths like 3.14159.

This was a reasonable trade-off for a scripting language meant to validate forms and animate web pages. Doubles can represent integers exactly up to 2^53 (about 9 quadrillion), which is more than enough for anything a web page would ever need. And having a single number type kept the language simple — no type casting, no overflow surprises between int and float, no confusion for beginners.

Thirty years later, we're trying to simulate a 64-bit processor inside that same number type. And this is where the trade-off bites.

A 64-bit RISC-V processor has 64-bit registers, 64-bit addresses, and 64-bit arithmetic. The emulator needs to manipulate these values bit by bit — shifting, masking, comparing. When Dart compiles to JavaScript, its `int` type maps directly to JavaScript's `number`. That means a 64-bit register value can silently lose its upper bits. No error, no warning. The emulator just starts computing wrong answers, and Linux crashes.

JavaScript does have `BigInt` now for arbitrary-precision integers, and bitwise operators that work in 32-bit ranges. But `BigInt` is too slow for an inner loop that runs millions of times per second, and 32 bits isn't enough for a 64-bit processor. There's no middle ground.

This isn't a Dart bug or something you can work around with clever code. It's baked into the foundations of how JavaScript represents numbers — a design decision from 1995 that every language compiling to JS inherits today.

### The Solution: A 32-bit Mode for the Web

Fortunately, RISC-V comes in both 32-bit and 64-bit flavours, and 32-bit values fit comfortably within JavaScript's safe integer range. The answer was to implement RV32 — a 32-bit variant of the processor — specifically for web builds, while keeping the full 64-bit version for native platforms (phones, desktops).

This is where RISC-V's clean design pays off. The 32-bit and 64-bit variants share the same instruction encodings and the same extension structure. The differences are well-defined: register width, a handful of 64-bit-only instructions, and the page table format. It's not a different architecture — it's a configuration option.

The CPU was split into 32-bit and 64-bit variants under the hood. Each instruction set extension gained a parallel 32-bit implementation. And certain large constants — bit patterns that are perfectly legal on native Dart but would cause a compile error on the web — were swapped out at compile time using Dart's conditional import system.

There's an irony to all of this. JavaScript's `number` type is 64 bits wide regardless of what value you store in it. A 32-bit register holding the value 7 still occupies a full 64-bit double in memory. The emulator is running a 32-bit processor specifically to avoid 64-bit precision problems, but every value it touches still costs 64 bits of storage. On native Dart, a 32-bit integer in a typed array takes exactly 4 bytes. On the web, it takes 8 — or more, once you account for object headers and garbage collector metadata. Multiply that across millions of memory accesses, register operations, and intermediate values, and the web build is paying a significant memory tax for the privilege of working at all.

### Death by Truncation

The most devious bug appeared after 32-bit mode was nominally working: the web build froze during boot. After investigation, the culprit turned out to be the floating-point registers.

Even in 32-bit mode, floating-point registers are 64 bits wide — they hold double-precision values. The register storage was backed by a 32-bit integer array, which silently chopped every value in half. This worked fine for single-precision floats, but when the Linux kernel tried to save and restore double-precision context during a task switch, the upper 32 bits were lost. The corrupted state sent the kernel into an infinite loop.

There are a few ways you could approach this. You could represent each 64-bit register using BigInt or a pair of integers wrapped in a class — essentially a software bitset. But these registers are read and written on almost every floating-point instruction. In an emulator's inner loop, that means millions of accesses per second. The overhead of heap-allocating objects, unpacking values, and garbage collecting the wrappers would cripple performance. What you need is something that stores the raw bits faithfully without any per-access cost.

The solution was to back the register file with a raw byte buffer. Each 64-bit register is stored as two 32-bit words at fixed offsets in a flat block of memory. Reads and writes go directly to the buffer using typed accessors — no objects created, no precision lost, no garbage to collect. When the floating-point unit needs to work with an actual `double` value, a separate accessor reads the same bytes as a native floating-point number, bypassing the integer representation entirely. A classic case of a data structure that looked correct but had a hidden platform assumption baked in.

### When Multiplication Lies

On a real 32-bit processor, multiplying two 32-bit numbers is a single hardware instruction. The CPU's multiply circuit handles the full-width result internally and gives you back whichever half you asked for. On native Dart, the same thing happens — `int` is a real integer type and multiplication just works.

On JavaScript, there's no such thing as a 32-bit integer. Those two "32-bit" values are actually 64-bit floating-point doubles. When you multiply them, JavaScript performs floating-point multiplication — and if the result exceeds 2^53, the double-precision format can't represent it exactly and silently rounds it. You get back a number that looks plausible but is wrong.

So the problem isn't that 32-bit multiplication is inherently hard. It's that JavaScript doesn't actually *have* 32-bit multiplication. It's faking it with floating-point, and the fake breaks down when the result gets large. The workaround is to break each multiply into smaller pieces — splitting the 32-bit values into 16-bit halves, multiplying those, and assembling the result. Each partial product stays within the safe range, and the final answer comes out correct. It's slower than a single native multiply, but it's the only way to get the right answer on the web.

## Day 4: Performance

With correctness established, the focus shifted to speed. The web build was noticeably slow.

Some of the fixes were straightforward: replacing linear scans with binary search for memory lookups, caching frequently accessed data views, and inlining the most common instructions (load, store, add, jump) directly into the main execution loop to eliminate function call overhead.

One optimisation was specific to how Dart compiles to JavaScript. The original design used nullable return values to signal errors (like page faults) from memory operations. On native Dart, nullable integers are cheap. On the web, dart2js has to "box" every nullable integer into a heap-allocated object. In the emulator's innermost loop — which runs millions of times per second — this boxing was a significant tax. Replacing nullable returns with a simple error flag on the CPU state eliminated the overhead entirely.

The Flutter execution model also needed rethinking. The emulator was originally driven by `setTimeout`-style timers, but browsers clamp these to a minimum of 1–4ms. Switching to requestAnimationFrame (via Flutter's Ticker) and running a fixed budget of instructions per frame dramatically improved throughput without blocking the UI.

## Day 5: Networking and Polish

The final push added networking. Not a simple mock — a full virtual network stack that lets the guest Linux system make real HTTP requests, resolve DNS names, and download files through the host's actual network connection.

This meant building from scratch: Ethernet frame handling, an ARP responder (so the guest can discover the virtual router), a DHCP server (so the guest gets an IP address automatically), DNS resolution (forwarding queries to the host system), and TCP/UDP proxying (connecting guest sockets to real host sockets with proper packet segmentation and acknowledgement tracking). All of this runs in pure Dart, with the actual network calls going through dart:io on native platforms.

The Flutter app also gained a config file picker with drag-and-drop support and the ability to load pre-built VM images from ZIP archives.

## Building the Boot Images

An emulator is useless without something to run on it. You need a bootloader, a Linux kernel compiled for RISC-V, and a root filesystem with an init system, shell, and enough utilities to actually do something. For the development variant, you also want a C compiler, make, git, and a text editor — a full working Linux environment.

Getting all of this to work together is its own project. The bootloader (OpenSBI) has to be compiled for the right RISC-V variant with the right privilege mode support. The kernel needs a minimal config targeting VirtIO devices, the right console driver (hvc0, not ttyS0), and ext2 filesystem support. The root filesystem has to be built for the correct architecture using a compatible C library (musl for RV32), with the right init scripts, mount points, and network configuration. Every piece has to agree on conventions — console device names, memory addresses, kernel command line parameters — or the system won't boot.

The build infrastructure ended up as a set of Docker-based scripts. One pipeline uses Alpine Linux's package manager to assemble a rootfs from pre-built packages. Another uses Buildroot — a full cross-compilation framework — to build everything from source for RV32, which takes 30+ minutes on a first run as it compiles an entire GCC toolchain. The outputs are ext2 filesystem images, paired with YAML config files that describe the machine layout, and bundled into ZIP archives that the Flutter app can load with drag-and-drop.

## The Role of AI

This project wouldn't have happened in five days without agentic coding. It might not have happened at all.

The emulator core — the CPU loop, the MMU, the instruction extensions — that's the interesting part. That's the work where you're thinking about how a processor actually functions, debugging why a privilege transition corrupts the stack pointer, figuring out why an interrupt fires one cycle too late. That's the work I wanted to do.

But surrounding that core is an enormous amount of cross-referencing drudgery. Building a Buildroot configuration that produces a bootable RV32 image with musl, busybox, and the right kernel options means reading Buildroot documentation, cross-referencing it with RISC-V ISA extension flags, matching the ABI (ILP32D for hardware float), getting the init system to use the right console device, and writing shell scripts that run inside a Docker container on a different architecture. Each individual step is straightforward. The combination of all of them, from a dozen different sources, is days of tedious lookup work.

The build scripts are a perfect example. The Buildroot image builder is about 180 lines of shell that sets up a cross-compilation environment, generates a kernel config, writes busybox fragment overrides, and produces a bootable ext2 image. I didn't write most of that by hand. I described what I needed — "build an RV32 Linux rootfs using Buildroot with musl and busybox, console on hvc0, optional dev tools" — and the AI assembled it from documentation and examples, cross-referencing the right config symbols, the right package names, the right Docker base image. What would have been a day or more of trial-and-error lookups was done in minutes.

The same pattern repeated across the project. The FDT builder (which generates the hardware description the kernel needs at boot), the VirtIO device registration, the network protocol handlers — all of these involve pulling together specifications and conventions from multiple sources and getting the details right. It's not creative work. It's not hard to *understand*. It's just a massive amount of boring, precise lookup. And that's exactly what AI is good at.

This freed me up to spend my time on the parts that actually matter: the CPU execution engine, the JavaScript workarounds, the performance tuning, the architectural decisions about how to split the codebase across platforms. The fun parts. AI handled the noise so I could focus on the signal.

Even this blog post was written with AI — specifically Claude Code, the same tool I used to build the emulator. Claude Code has full context of the codebase: every source file, every commit message, the git history, the build scripts, the project structure. When I asked it to help write up the project history, it could walk the commit log, read the actual implementation, cross-reference the code with the git messages, and produce a narrative grounded in what actually happened rather than what I half-remembered. I'd steer it — "explain why RISC-V", "expand the JavaScript section", "the tone is too technical, assume the reader writes JavaScript not assembly" — and it would revise with the full codebase as context.

It's a reminder that tools like Claude Code aren't just for writing code. Anything that benefits from having the full project context at hand — documentation, blog posts, changelogs, architecture overviews — is a natural fit. The AI isn't guessing what the code does. It's reading it.

## Architecture Overview

The final codebase is roughly 12,500 lines of Dart across ~75 source files:

| Component | Lines | What it does |
|-----------|-------|--------------|
| CPU executor | 2,866 | Reads, decodes, and executes instructions |
| ISA extensions | ~2,000 | Multiply, atomic, compressed, and floating-point instruction sets |
| Memory management | 517 | Virtual-to-physical address translation |
| Control registers | 355 | Privilege levels, interrupt configuration |
| Machine layer | ~1,500 | Physical memory layout, timers, interrupt routing |
| Virtual devices | ~1,200 | Console, hard drive, network card, input |
| Networking | ~1,200 | Full network stack: Ethernet, IP, TCP, UDP, DNS, DHCP |
| Emulator API | ~300 | The public interface for embedding in apps |

## What's Left

DartEMU boots Linux and it works, but it's far from finished. Performance on the web is functional rather than fast — there's plenty of room for smarter instruction caching, better memory access patterns, and tighter compilation output. The networking stack handles the basics but doesn't cover every edge case a real TCP implementation would. WASM support is there but hasn't been deeply optimised for. And the whole project could benefit from more thorough testing — the kind of systematic validation where you run the RISC-V compliance test suites and chase down every last discrepancy.

It's a working proof of concept, not a polished product. But that was always the point — finding out whether Dart could do this at all, and where the rough edges are. The rough edges are real, and smoothing them out is where the next round of interesting work lives.

## What I Learned

**RISC-V is a joy to implement.** When something didn't work, the answer was always in the specification — not in an errata document or a forum post about undocumented behaviour. The modular extension system meant I could bring up the basics first and layer in complexity incrementally, testing at each stage.

**JavaScript's number model is a real constraint.** It's not just an inconvenience — it fundamentally limits what you can run on the web. The 53-bit precision boundary shows up everywhere: register values, bit masks, multiplication, memory addresses. You can't paper over it. You have to design around it.

**Emulators are all about the edge cases.** The core instruction loop is conceptually simple — fetch, decode, execute, repeat. But instructions that cross page boundaries, privilege level transitions, interrupt timing, and data corruption from platform-specific type behaviour — that's where the real debugging happens.

**Dart works.** A language usually associated with mobile apps can boot Linux and run a network stack. It's not as fast as C, but it's fast enough — and the ability to embed a full system emulator as a Flutter widget on six platforms from one codebase is something no systems language can offer.

## Try It

DartEMU is on [pub.dev](https://pub.dev/packages/dart_emu) and [GitHub](https://github.com/LeeMatthewHiggins/DartEMU). It runs on iOS, Android, macOS, Linux, Windows, and the web.
