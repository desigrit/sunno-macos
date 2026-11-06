import Foundation

@main
struct StartupDiagnosticsChecks {
    static func main() {
        let diagnostics = EngineDiagnostics()
        let timing = "[startup] stage=control_ready duration_ms=120 elapsed_ms=120 result=ok"
        precondition(!diagnostics.note(String(timing.prefix(20))))
        precondition(diagnostics.collected() == nil)
        precondition(diagnostics.note(String(timing.dropFirst(20)) + "\n"))
        precondition(diagnostics.collected() == timing)
        precondition(!diagnostics.note("[startup] stage=private_name duration_ms=1 elapsed_ms=1 result=ok\n"))
        precondition(!diagnostics.note("[startup] stage=model_load duration_ms=1 elapsed_ms=1 result=ok private caption\n"))
        precondition(diagnostics.collected() == timing)
        diagnostics.note("[error] model unavailable\n")
        precondition(diagnostics.collected()?.contains("[error] model unavailable") == true)
        diagnostics.note("[startup] stage=")
        diagnostics.reset()
        precondition(diagnostics.collected() == nil)
        precondition(diagnostics.note(timing + "\n"))
        print("Startup diagnostics and split readiness checks passed.")
    }
}
