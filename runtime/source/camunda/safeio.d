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

// ---- Threads and shared state ----------------------------------------------
//
// The "E profile" (as in nano-coder-d): threads start only through `spawn`,
// which takes a plain `function` (no hidden closure context) and sendable
// arguments; threads talk through `Chan`s of sendable values or `Locked`
// state. check-safe.sh bans `new Thread` and `__gshared` outside this module,
// so data shared between threads is visible in the types.

import core.sync.condition : Condition;
import core.thread : Thread;
import std.meta : allSatisfy, staticMap;
import std.traits : hasUnsharedAliasing, Unqual;

/// A value shared between threads that is only reachable under its lock.
/// Declare it `shared` (`shared Locked!T x = new shared Locked!T;`): the
/// compiler then rejects any access that bypasses `get`/`update`/`await`.
/// `T` may not hold unshared mutable references, so neither a copy out of
/// `get` nor anything `update` stores can alias the locked value from
/// another thread.
final class Locked(T) if (!hasUnsharedAliasing!T)
{
    import core.sync.mutex : Mutex;
    private T value;
    private Mutex mutex;
    private Condition changed;

    /// `@trusted`: casts away `shared` only on a freshly built object.
    this(T v = T.init) shared @trusted
    {
        auto self = cast() this;
        self.value = v;
        self.mutex = new Mutex;
        self.changed = new Condition(self.mutex);
    }

    /// A copy of the value.
    /// `@trusted`: the unshared view of `value` is used only under the lock.
    T get() shared @trusted
    {
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        return self.value;
    }

    /// Run `f` on the value under the lock, and wake `await`ers. `f` is
    /// `scope`: it can't keep the reference.
    /// `@trusted`: as for `get`; the `ref` can't outlive `f` (DIP1000).
    R update(R = void)(scope R delegate(ref T) @safe f) shared @trusted
    {
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        scope (exit) self.changed.notifyAll();
        return f(self.value);
    }

    /// Block until `ready(value)` holds (or `timeoutMs` passes, when it is
    /// positive), then run `f` under the same lock.
    /// `@trusted`: as for `update`.
    R await(R = void)(scope bool delegate(ref const T) @safe ready, scope R delegate(ref T) @safe f,
        long timeoutMs = 0) shared @trusted
    {
        import core.time : MonoTime, msecs;
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        const deadline = MonoTime.currTime + timeoutMs.msecs;
        while (!ready(self.value))
        {
            if (timeoutMs <= 0) self.changed.wait();
            else
            {
                const left = deadline - MonoTime.currTime;
                if (left <= 0.msecs) break;
                self.changed.wait(left);
            }
        }
        scope (exit) self.changed.notifyAll();
        return f(self.value);
    }
}

@safe unittest
{
    static struct S { int n; string s; }
    shared Locked!S l = new shared Locked!S(S(1, "a"));
    l.update((ref S v) { v.n++; });
    assert(l.get == S(2, "a"));
    static assert(!__traits(compiles, new shared Locked!(int[])));
    // A bounded await returns once the timeout passes, even if not ready.
    l.await((ref const S v) => v.n == 99, (ref S v) {}, 20);
}

/// A reference to an object of a class whose every method is internally
/// synchronized (Rust's `Sync`), so it may be used from several threads at
/// once. The compiler can't check that promise; each `assumeThreadSafe`
/// call site is the reviewed claim, and must say why it holds.
struct ThreadSafe(T) if (is(T == class))
{
    private shared T payload;

    /// Claim that every method of `value` may be called from any thread
    /// concurrently.
    /// `@trusted`: the claim is the caller's; the cast only records it.
    static ThreadSafe assumeThreadSafe(T value) @trusted
    {
        import core.atomic : atomicStore;
        ThreadSafe r;
        atomicStore(r.payload, cast(shared) value);
        return r;
    }

    /// The object, for this thread to call.
    /// `@trusted`: sound by the `assumeThreadSafe` claim.
    T get() const @trusted
    {
        import core.atomic : atomicLoad;
        return cast(T) atomicLoad(payload);
    }
}

/// Whether a value of type `T` may be handed to another thread: it holds no
/// unshared mutable references (immutable, `shared` or plain data, function
/// pointers), or it is a `ThreadSafe` reference. Delegates are not sendable:
/// their context can reach anything.
enum bool isSendable(T) = !hasUnsharedAliasing!T || is(T : ThreadSafe!U, U);

/// A started thread; `join` waits for it and rethrows what killed it.
struct JoinHandle
{
    private Thread thread;

    /// Wait for the thread to finish (rethrows what killed it).
    /// `@trusted`: `Thread.join` is unattributed; it only waits.
    void join() @trusted
    {
        if (thread !is null) thread.join();
    }

    /// Whether the thread is still running (false once it has returned).
    /// `@trusted`: `Thread.isRunning` is unattributed; it only reads state.
    bool running() const @trusted
    {
        return thread !is null && (cast() thread).isRunning;
    }
}

private final class SpawnBox(Args...) { staticMap!(Unqual, Args) args; }

/// Run `fn(args)` on a new thread. `fn` is a plain function, so it can only
/// reach what it is given (and `shared` or thread-local globals), and every
/// argument must be sendable.
JoinHandle spawn(Args...)(void function(Args) @safe fn, auto ref Args args)
    if (allSatisfy!(isSendable, Args))
{
    return startSpawned(fn, args);
}

/// `@trusted`: the arguments (checked sendable by `spawn`) are moved into a
/// box only the new thread can reach; `shared` is stripped for the move and
/// restored for the call. `fn` is a context-free function.
private JoinHandle startSpawned(Args...)(void function(Args) @safe fn, ref Args args) @trusted
{
    import core.lifetime : move;
    auto box = new SpawnBox!Args;
    static foreach (i; 0 .. Args.length)
        box.args[i] = move(*cast(Unqual!(Args[i])*) &args[i]);
    auto t = new Thread({ mixin("fn(" ~ callArgs!(Args.length) ~ ");"); });
    JoinHandle h;
    h.thread = t.start();
    return h;
}

private template callArgs(size_t n)
{
    import std.conv : to;
    enum callArgs = () {
        string r;
        foreach (i; 0 .. n) r ~= (i ? ", " : "") ~ "cast(Args[" ~ i.to!string ~ "]) move(box.args[" ~ i.to!string ~ "])";
        return r;
    }();
}

/// A handle to a `Channel`: copyable and sendable, so each thread holds its
/// own. `Chan!T.make` creates one.
struct Chan(T)
{
    import core.atomic : atomicLoad;
    private shared Channel!T impl;

    /// A new, open channel.
    static Chan make() { return Chan(new shared Channel!T); }
    /// See `Channel`.
    void put(T v) { atomicLoad(impl).put(v); }
    /// ditto
    void close() { atomicLoad(impl).close(); }
    /// ditto
    bool take(out T v) { return atomicLoad(impl).take(v); }
    /// ditto
    bool tryTake(out T v) { return atomicLoad(impl).tryTake(v); }
    /// ditto
    bool takeFor(out T v, long ms) { return atomicLoad(impl).takeFor(v, ms); }
}

/// A blocking FIFO of sendable values between threads, closable. Use it
/// through `Chan`.
final class Channel(T) if (!hasUnsharedAliasing!T)
{
    import core.sync.mutex : Mutex;
    private Mutex lock;
    private Condition ready;
    private T[] items;
    private size_t head;
    private bool closed;

    /// `@trusted`: initialises the fresh object's own lock.
    this() shared @trusted
    {
        auto self = cast() this;
        self.lock = new Mutex;
        self.ready = new Condition(self.lock);
    }

    /// Append `v`; wakes one taker.
    /// `@trusted`: the unshared view is used only while holding `lock`.
    void put(T v) shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        self.items ~= v;
        self.ready.notify();
    }

    /// No more values: takers drain what is left, then get false.
    /// `@trusted`: as for `put`.
    void close() shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        self.closed = true;
        self.ready.notifyAll();
    }

    /// Wait for the next value; false once closed and empty.
    bool take(out T v) shared { return takeImpl(v, true); }

    /// The next value if one is queued now (never waits); false otherwise.
    bool tryTake(out T v) shared { return takeImpl(v, false); }

    /// Wait up to `ms` milliseconds for the next value; false on timeout
    /// or once closed and empty.
    bool takeFor(out T v, long ms) shared { return takeImpl(v, true, ms); }

    /// `@trusted`: as for `put`.
    private bool takeImpl(out T v, bool wait, long ms = -1) shared @trusted
    {
        import core.time : MonoTime, msecs;
        const deadline = ms >= 0 ? MonoTime.currTime + ms.msecs : MonoTime.max;
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        while (wait && self.head == self.items.length && !self.closed)
        {
            if (ms < 0) self.ready.wait();
            else
            {
                const left = deadline - MonoTime.currTime;
                if (left <= left.zero) break;
                self.ready.wait(left);
            }
        }
        if (self.head == self.items.length) return false;
        v = self.items[self.head];
        self.items[self.head] = T.init;
        self.head++;
        if (self.head == self.items.length)
        {
            self.items.length = 0;
            self.items.assumeSafeAppend();
            self.head = 0;
        }
        return true;
    }
}

@safe unittest // spawn + Chan carry values between threads
{
    static void worker(Chan!int input, Chan!int output)
    {
        int v;
        while (input.take(v)) output.put(v * 2);
        output.close();
    }
    auto input = Chan!int.make;
    auto output = Chan!int.make;
    auto h = spawn(&worker, input, output);
    foreach (i; 1 .. 4) input.put(i);
    input.close();
    int v, sum;
    while (output.take(v)) sum += v;
    h.join();
    assert(sum == 12);
    static assert(isSendable!string && isSendable!(Chan!int) && isSendable!(ThreadSafe!Object));
    static assert(!isSendable!(int[]) && !isSendable!(void delegate()) && !isSendable!Object);
    static void bad(int[] a) {}
    static assert(!__traits(compiles, spawn(&bad, [1])));
}

/// A mutex for a class that synchronizes its own methods (see
/// `ThreadSafe`): `run` executes `f` while holding it. Not reentrant across
/// objects: never call out to another `Lock` holder's methods from `f` in a
/// cycle.
final class Lock
{
    import core.sync.mutex : Mutex;
    private Mutex mutex;

    /// `@trusted`: builds the object's own mutex.
    this() @trusted { mutex = new Mutex; }

    /// Run `f` under the lock. Usable from `const` methods: locking changes
    /// no observable state of the owner.
    /// `@trusted`: `Mutex` methods are unattributed; the cast only drops
    /// `const` from the mutex, which is locked and unlocked, never replaced.
    R run(R)(scope R delegate() @safe f) const @trusted
    {
        auto m = cast() mutex;
        m.lock();
        scope (exit) m.unlock();
        return f();
    }
}

@safe unittest // Lock serializes increments from several threads
{
    static final class Counter
    {
        Lock lock;
        long n;
        this() { lock = new Lock; }
        void bump() { lock.run({ n++; }); }
    }
    static void hammer(ThreadSafe!Counter c)
    {
        foreach (_; 0 .. 10_000) c.get.bump();
    }
    // Counter synchronizes every access to `n` through `lock`.
    auto c = ThreadSafe!Counter.assumeThreadSafe(new Counter);
    JoinHandle[4] hs;
    foreach (ref h; hs) h = spawn(&hammer, c);
    foreach (ref h; hs) h.join();
    assert(c.get.lock.run(() => c.get.n) == 40_000);
}

@safe unittest // takeFor times out on an empty channel and returns a queued value
{
    auto c = Chan!int.make;
    int v;
    assert(!c.takeFor(v, 5));
    c.put(7);
    assert(c.takeFor(v, 5) && v == 7);
}
