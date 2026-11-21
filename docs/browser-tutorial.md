# Browser tutorial

<!-- cspell:words esac -->

[Open the live tutorial](https://leematthewhiggins.github.io/DartEMU/) to run
these examples in a real RV32 Linux guest. It runs on your device without
an account or installation.

## Start your machine

The embedded terminal boots automatically. Wait for **Linux is ready** and
the `~ #` shell prompt, then select **Run example**. The button runs
the displayed command and marks the lesson explored when the shell returns.
Each example supplies its own input, so you can run them in any order.

Use the numbered tabs or **Next lesson** to move between examples.
**First lesson** returns to the start after the last example. With a tab
focused, Left/Right arrows switch lessons; Home/End select the first/last. **Copy command** copies without running it. Click the
terminal, paste, then press Enter to run a copied command.

## 1. Inspect the machine

```sh
uname -m; cat /proc/cpuinfo
```

The first line is `riscv32`, followed by the emulated CPU's details. This
describes the guest, regardless of your device's processor.

## 2. Record temperatures

```sh
mkdir -p /tmp/tutorial
printf '%s\n' 'roof 18' 'garden 24' 'attic 31' 'cellar 16' > /tmp/tutorial/weather.txt
cat /tmp/tutorial/weather.txt
```

Expected output:

```text
roof 18
garden 24
attic 31
cellar 16
```

`>` writes the sample temperatures in Celsius to a file; `cat` reads it.
Running this again replaces the file with the same data.

## 3. Find the warmest places

```sh
printf '%s\n' 'roof 18' 'garden 24' 'attic 31' 'cellar 16' |
  sort -r -k2 |
  head -n 2
```

Expected output:

```text
attic 31
garden 24
```

The pipes pass data between tools. These two-digit readings sort correctly
as text. `sort -r -k2` puts the highest second field first; `head -n 2`
keeps the top two rows.

## 4. Draw a temperature chart

```sh
printf '%s\n' 'roof 18' 'garden 24' 'attic 31' 'cellar 16' |
  while read place temp; do
    printf '%-7s ' "$place"
    i=0
    while [ "$i" -lt "$temp" ]; do
      printf '#'
      i=$((i + 1))
    done
    echo " $temp C"
  done
```

Expected output:

```text
roof    ################## 18 C
garden  ######################## 24 C
attic   ############################### 31 C
cellar  ################ 16 C
```

The outer loop reads each row. The inner loop counts up and prints one `#`
per degree. Fixed-width labels align the bars.

## 5. Render a fractal

The guest computes each character of this Mandelbrot image. It uses integers
scaled by 100 to calculate an escape count for each point.

```sh
limit=16
y=-8
while [ "$y" -le 8 ]; do
  row=; x=-30
  while [ "$x" -le 10 ]; do
    a=0; b=0; n=0
    while [ "$((a*a+b*b))" -le 40000 ] &&
          [ "$n" -lt "$limit" ]; do
      t=$(((a*a-b*b)/100+x*7))
      b=$((2*a*b/100+y*14))
      a=$t; n=$((n+1))
    done
    case $n in
      "$limit") p=@;;
      [0-2]) p=' ';;
      [3-5]) p=.;;
      [6-9]) p='*';;
      *) p=+;;
    esac
    row="$row$p"; x=$((x+1))
  done
  printf '%s\n' "$row"
  y=$((y+1))
done
```

Expected output is a 41-column, 17-row fractal. `@` marks points that reach
the iteration limit. Increase `limit` to 32 to calculate more iterations
and compare the result.

## Terminal controls

Output stays in view until you scroll up; **Run example** resumes following
new output.

Click inside the terminal before typing. Press Enter to run a command and
Ctrl+C to interrupt a command that is still running. Ctrl+A and Ctrl+V go
to the guest shell, so use the terminal's copy/paste controls instead:

| Action | Control |
| --- | --- |
| Copy / Paste / Select all | Right-click terminal menu |
| Copy selected terminal text | Ctrl+Insert; Cmd+C on macOS |
| Paste into the terminal | Shift+Insert; Cmd+V on macOS |
| Alternative copy/paste | Ctrl+Shift+C / Ctrl+Shift+V, subject to browser shortcuts |
| Select all on macOS | Cmd+A |

On a touch device, use **Run example** to complete the lessons without
a keyboard. Clipboard troubleshooting is below.

## Reset and keep exploring

**Restart** asks for confirmation, then discards guest files and lesson
progress. Reloading or closing the page also loses them.

**Open terminal** starts a new machine in a separate tab with its own files
and output.

The tutorial's small RV32 image has BusyBox shell tools, no C compiler, and
no external network access configured. To compile C, open the
[RV64 Firebase demo](https://dartemu-3ef91.web.app/?boot=64) in a browser
with WasmGC support. GitHub Pages serves the RV32 JavaScript build.

To load your own image, open the
[image picker](https://leematthewhiggins.github.io/DartEMU/terminal.html)
and import a [ZIP bundle](configuration.md#bundles). For a first bundle,
[preload the included RV32 example](https://leematthewhiggins.github.io/DartEMU/terminal.html?bundle=vms/rv32-demo.zip)
and press Boot. See [Embedding](embedding.md) to use the library in your
own application.

## If something gets stuck

| Symptom | What to try |
| --- | --- |
| Waiting for Linux | Keep the tab visible while assets load and Linux boots. If it remains stuck, restart or open a separate terminal. |
| An example does not run after you typed | Finish your command, or click the terminal and press Ctrl+C to return to a fresh prompt, then try again. Examples run only when the shell is idle. |
| A command is still running | Click the terminal and press Ctrl+C. Restart if the shell does not recover. |
| You ran `poweroff` | Restart to boot a new guest. |
| Clipboard action failed | Allow browser clipboard access, or select and copy the displayed command manually. |
| RV64 opens the picker | The browser is using JavaScript. Use RV32, or the Firebase Wasm build in a compatible browser. |
