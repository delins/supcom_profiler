<img width="2558" height="873" alt="image" src="https://github.com/user-attachments/assets/9463752d-fd86-4d54-98ba-6975529892b5" />

## Overview

This is a profiler for Supreme Commander Forged Alliance, specifically made to work with the Loud
mod. Whether it works with FAF hasn't been tested. 

It records complete callstacks by obsering every function call and function return, and tracks
how much time was spent while the function was running. It stores various other metrics as well,
such as the number of times a function was called. All this information is written to the standard
Loud log, one line per callstack. You can then convert the logged profiler data to the "stackcollapse"
format for analysis.

## Usage

The simplest way to make the profiler work is to append the code in "profiler.lua" to
"LOUD/gamedata/lua/lua/simInit.lua". You then have the option to toggle the profiler using hotkeys
(`CTRL + O` to start, `CTRL + P` to stop), or you schedule the profiler to run at a given time window.
To use the hotkeys you need cheats enabled. If you want to schedule the profile run, look at 
`ScheduleProfiler` at the bottom of "profiler.lua". It's currently scheduled to run from minute 1
to minute 2.

Once profiling stops the collected data is written to the standard supcom logfile. You recognize
the profiler's output by lines starting with `info: prof: `. Each line contains one callstack with
its collected profile data, and lines are sorted by how much time was spent in the callstack in 
ascending order.

The profiler's output can be converted to the "stackcollapse" format by using the Python package
"supcom_profiler_converter" in this repo. This file can then be fed into https://www.speedscope.app/
for analysis.

You can find an example profiler output in "example/log.txt", and the corresponding stackcollapse
file in "example/profile_stackcollapse.txt". 

The rest of the text below is about the Lua code details.

## Implementation details for the Lua code

### The main thread and coroutines

While the sim utilizes one CPU core, it does spawn and use many logical threads aka coroutines,
in Lua space. These run a while to do their thing and when they decide they're done for the moment 
they inform the Lua runtime that they can go to sleep for a while. The Lua runtime can then
schedule other threads (either coroutines or the main thread) to run.

Each thread has its on stack: when it's a couple functions deep and calls `WaitTicks` and
therefore yields, it keeps that same state when control returns to that thread by means of 
`WaitTicks` returning (followed by another call, see "Yielding functions ..." below). So we have
to manage all this state in the profiler.

More modern Lua's have an additional parameter in `debug.sethook` that states what coroutines 
should get hooked, but in the supcom Lua (modified 5.0.1) all we need is a single `debug.sethook`
to hook the main thread, and all coroutines, both existing and future ones.


### Blacklisting functions

When seeing a function that hooks function calls, and seeing that that function calls other
functions, you may get anxious. No need to worry, the function calls originating from the hooked
functions seem to get excempted from getting hooked themselves. The only functions that we want to
block are the `debug.sethook`, specifically (and only) for its return action, and our own profiler
toggle functions.


### Dealing with profiler kickoff midgame

If the profiler were started before the sim runs, it would see every call and return that takes 
place. Its tracking of the sim state would be perfect. However, the most representative profiling
data is collected later in the game, preferably when the sim has started to slow down.

When we start the profiler mid-game we don't know when the currently running functions started,
so once they return we don't know what the real duration of that function call was. Our approach
to deal with that is to, for each thread, analyze the current callstack the first time we're in
the hook function for that thread, and set the start time to the current time. We keep doing this
for all new threads, even those that spawn after profiling started. But it doesn't add much cost.


### Yielding functions (WaitFor, WaitTicks, etc)

Threads (coroutines) can be suspended by calling `WaitFor` and similar yielding functions from
within that thread. By doing so, they yield control back to the Lua runtime so that it can progress
other threads. At some point in the future the yielding thread may be resumed again. 

This poses a challenge when profiling: when our hook function sees a call to a yielding function at game
time 5:00 and sees the return of it (which implies that the thread is resumed) at 6:00, we
could conclude that this function is very expensive. After all, the function call took 1 minute of 
wall clock time to complete. This would be wrong. It would also mean that this false duration is
propagated up the stack to the parents, which would also look like they were very expensive.

We solve this by checking whether the current function is one of the yielding functions, and if so,
set the yielding function call's duration to 0s. We also add the duration during which the thread 
was suspended to our direct parent's duration correction. When the parent returns it will first 
take note of its entire duration in terms of wall-clock time, and subtract the duration correction.
It also pushes its accumulated duration correction to its parent, etc.

We also need to deal with the first call action that we see for a thread that has resumed: it will
denote the line in the function that execution will continue on. Typically the line after the
yielding function. There's no return for this call, so if we aren't careful, in the end it would
look like we recursed very deeply. The solution is to flag that we returned from a yielding function,
and discard the first call that happens that follows it in the same thread.


### Missing function names

For Lua functions, we retrieve a frame's source file, source line, current function name and
current line with debug.getinfo. For forked threads, however, the function name is empty for all
functions that live in the same Lua file (or probably more correctly: the same Lua chunk) as the
function that was passed to ForkThread. I don't know why but it seems to be normal behavior for
debug.getinfo.


### Return lines, return, and tail return

With `return` actions in our hook function, `debug.getinfo` gives us the line that execution in the
function returned from. This is typically the line that has `end`, that closes the function's body.
It can also be a line with `return someValue`

There's a special case of returns, called the `tail return`. Normally these happen when a function
returns with a function call, eg `return someFunction()`. These tail returns also seem to show
themselves around `ForkThread` calls (and maybe others?), Regardless of when they happen, we can
almost treat them like a regular return, with one caveat: the `currentInfo` we create will not
contain the frame we're returning from, but the frame the interpreter seems to be jumping to? Not
sure. The current_line has a bogus value, which looks like an uninitialized int in the C runtime.
So in case of frames that are returned from using tail returns we use the information we stored
when the function was called, and we don't have a return line.

