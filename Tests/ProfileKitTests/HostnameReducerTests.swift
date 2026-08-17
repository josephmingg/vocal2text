import ProfileKit
import Testing

// MARK: - hostname(fromTabURL:)

@Test func hostnameStripsPathAndQuery() {
    #expect(
        HostnameReducer.hostname(fromTabURL: "https://docs.google.com/document/d/abc123/edit?tab=t.0")
            == "docs.google.com"
    )
}

@Test func hostnameStripsFragment() {
    #expect(
        HostnameReducer.hostname(fromTabURL: "https://mail.google.com/mail/u/0/#inbox")
            == "mail.google.com"
    )
}

@Test func hostnameStripsPort() {
    #expect(HostnameReducer.hostname(fromTabURL: "http://localhost:8080/admin") == "localhost")
}

@Test func hostnameStripsLeadingWWW() {
    #expect(HostnameReducer.hostname(fromTabURL: "https://www.example.com") == "example.com")
}

@Test func hostnameLowercasesHost() {
    #expect(HostnameReducer.hostname(fromTabURL: "https://WWW.Example.COM/Path") == "example.com")
}

@Test func hostnameStripsOnlyOneWWWLabel() {
    #expect(HostnameReducer.hostname(fromTabURL: "https://www.www.example.com") == "www.example.com")
}

@Test func hostnameKeepsBareDomain() {
    #expect(HostnameReducer.hostname(fromTabURL: "https://google.com") == "google.com")
}

@Test func hostnameRejectsNonHTTPSchemes() {
    #expect(HostnameReducer.hostname(fromTabURL: "file:///Users/me/notes.txt") == nil)
    #expect(HostnameReducer.hostname(fromTabURL: "ftp://ftp.example.com/pub") == nil)
    #expect(HostnameReducer.hostname(fromTabURL: "mailto:someone@example.com") == nil)
    #expect(HostnameReducer.hostname(fromTabURL: "about:blank") == nil)
}

@Test func hostnameRejectsMissingHost() {
    #expect(HostnameReducer.hostname(fromTabURL: "https://") == nil)
    #expect(HostnameReducer.hostname(fromTabURL: "") == nil)
    #expect(HostnameReducer.hostname(fromTabURL: "not a url") == nil)
}

// MARK: - matches(routeHostname:actual:)

@Test func matchesExactHost() {
    #expect(HostnameReducer.matches(routeHostname: "google.com", actual: "google.com"))
}

@Test func matchesSubdomainSuffix() {
    #expect(HostnameReducer.matches(routeHostname: "google.com", actual: "mail.google.com"))
}

@Test func matchesDeepSubdomainSuffix() {
    #expect(HostnameReducer.matches(routeHostname: "google.com", actual: "a.b.google.com"))
}

@Test func matchesRejectsNotGoogleTrap() {
    #expect(!HostnameReducer.matches(routeHostname: "google.com", actual: "notgoogle.com"))
}

@Test func matchesRejectsRouteEmbeddedOnWrongSide() {
    #expect(!HostnameReducer.matches(routeHostname: "google.com", actual: "google.com.evil.com"))
}

@Test func matchesRejectsRouteMoreSpecificThanActual() {
    #expect(!HostnameReducer.matches(routeHostname: "mail.google.com", actual: "google.com"))
}

@Test func matchesIsCaseInsensitive() {
    #expect(HostnameReducer.matches(routeHostname: "Google.COM", actual: "MAIL.google.com"))
}

@Test func matchesRejectsEmptyInputs() {
    #expect(!HostnameReducer.matches(routeHostname: "", actual: "google.com"))
    #expect(!HostnameReducer.matches(routeHostname: "google.com", actual: ""))
    #expect(!HostnameReducer.matches(routeHostname: "", actual: ""))
}
