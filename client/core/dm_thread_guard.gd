class_name DmThreadGuard
extends RefCounted
## The rule for work off the main thread (client/README.md "Threads"): a worker computes DATA and hands it back; whatever touches the scene tree, a Node, a signal or a
## Godot object that is not thread-safe happens on the main thread, after the worker has finished. The places that apply a worker's result call `assert_main` first, so a
## refactor that moves the apply onto a thread names itself in the log and in `violations` (the suites check it is 0) instead of crashing a player at random.
##
## Not here: a worker's own body. `WorkerThreadPool.wait_for_task_completion` lets the waiting thread run a task that has not started, so a body may legitimately run on the
## main thread; what must never happen is the apply path running anywhere else.

static var checks := 0        ## apply paths that passed through `assert_main` (the suites check it is not 0: the path was exercised)
static var violations := 0    ## apply paths that ran off the main thread (the suites check it is 0)
static var last_violation := ""


static func on_main() -> bool:
	return OS.get_thread_caller_id() == OS.get_main_thread_id()


## True on the main thread. Off it: counts the violation and reports it, naming `what` and the thread (the apply path is then unsafe, whatever it touches next).
static func assert_main(what: String) -> bool:
	checks += 1
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		return true
	violations += 1
	last_violation = what
	push_error("DmThreadGuard: %s ran on thread %d, not the main thread" % [what, OS.get_thread_caller_id()])
	return false
