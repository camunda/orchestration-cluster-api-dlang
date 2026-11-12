/// Small `@trusted` wrappers around Phobos / libcurl / POSIX that the rest of
/// the SDK can call from `@safe` code. Each annotation is an unchecked
/// promise; keep this file as small as the C boundary. Review it like Rust
/// `unsafe`.
module camunda.safeio;

@safe:

import std.json;
import std.stdio : File;

/// `std.file.read` as bytes. The `void[]` it returns is freshly allocated
/// and untyped, so viewing it as `ubyte[]` aliases nothing else.
ubyte[] readBytes(string path) @trusted
{
    import std.file : read;
    return cast(ubyte[]) read(path);
}

/// `std.file.read` as (possibly invalid) UTF-8 text, without validating it.
string readRawText(string path) @trusted
{
    import std.file : read;
    return cast(string) read(path);
}

/// Write `bytes` to `path`, replacing any existing file.
void writeBytes(string path, const(ubyte)[] bytes) @trusted
{
    import std.file : write;
    write(path, bytes);
}

/// Write `text` to `path`, replacing any existing file.
void writeText(string path, string text) @trusted
{
    import std.file : write;
    write(path, text);
}

/// `std.file.exists`.
bool pathExists(string path) @trusted
{
    import std.file : exists;
    return exists(path);
}

/// `std.file.mkdirRecurse`.
void makeDirRecurse(string path) @trusted
{
    import std.file : mkdirRecurse;
    mkdirRecurse(path);
}

/// `std.file.rename`.
void renamePath(string from, string to) @trusted
{
    import std.file : rename;
    rename(from, to);
}

/// `std.file.remove`; ignore missing files.
void removePath(string path) @trusted
{
    import std.file : exists, remove;
    if (exists(path)) remove(path);
}

/// `std.stdio.stderr`.
@property ref File stdErr() @trusted
{
    import std.stdio : stderr;
    return stderr;
}

/// `environment.get`. Phobos marks the process environment `@system`.
string envGet(string key) @trusted
{
    import std.process : environment;
    return environment.get(key, null);
}

/// `thisProcessID` as a decimal string, for temp-file names.
string thisPidString() @trusted
{
    import std.conv : to;
    import std.process : thisProcessID;
    return thisProcessID.to!string;
}

/// Sleep for `ms` milliseconds. `Thread.sleep` is `@system`.
void sleepMs(long ms) @trusted
{
    import core.thread : Thread;
    import core.time : msecs;
    if (ms < 0) ms = 0;
    Thread.sleep(ms.msecs);
}

/// A byte buffer nothing else references, viewed as (possibly invalid) UTF-8.
string ownText(ubyte[] unique) @trusted pure nothrow
{
    return cast(string) unique;
}

/// `ownText` for a `char[]` buffer the caller uniquely owns.
string ownText(char[] unique) @trusted pure nothrow
{
    return cast(string) unique;
}

/// Uniform random in `[0, 1)`. `std.random.uniform01` is `@system` because
/// it touches thread-local RNG state.
double unitRandom() @trusted
{
    import std.random : uniform01;
    return uniform01();
}

/// Current wall-clock milliseconds since the Unix epoch.
long wallNowMs() @trusted
{
    import std.datetime.systime : Clock, unixTimeToStdTime;
    import core.time : hnsecs;
    auto st = Clock.currTime();
    return st.toUnixTime!long * 1000
        + (st.fracSecs.total!"msecs");
}

/// Current monotonic milliseconds (steady clock).
long monoNowMs() @trusted
{
    import core.time : MonoTime;
    return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1000);
}

/// Process-wide live-clock singleton. Written once, then only read.
/// `@trusted`: `__gshared` is confined to this file; the object has no
/// mutable shared state of its own.
T liveSingleton(T)() @trusted
    if (is(T == class))
{
    static __gshared T slot;
    if (slot is null) slot = new T;
    return slot;
}
