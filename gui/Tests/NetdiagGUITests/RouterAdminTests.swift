import Foundation
import Testing
@testable import NetdiagGUI

@Suite struct RouterAdminTests {

    @Test func validatesRFC1918Addresses() {
        // 10.0.0.0/8
        #expect(IPAddressValidation.isRFC1918PrivateIPv4("10.0.0.1"))
        #expect(IPAddressValidation.isRFC1918PrivateIPv4("10.255.255.254"))
        #expect(IPAddressValidation.isRFC1918PrivateIPv4(" 10.1.2.3 "))

        // 172.16.0.0/12
        #expect(IPAddressValidation.isRFC1918PrivateIPv4("172.16.0.1"))
        #expect(IPAddressValidation.isRFC1918PrivateIPv4("172.20.1.1"))
        #expect(IPAddressValidation.isRFC1918PrivateIPv4("172.31.255.254"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("172.15.255.255"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("172.32.0.1"))

        // 192.168.0.0/16
        #expect(IPAddressValidation.isRFC1918PrivateIPv4("192.168.1.1"))
        #expect(IPAddressValidation.isRFC1918PrivateIPv4("192.168.0.1"))
        #expect(IPAddressValidation.isRFC1918PrivateIPv4("192.168.254.254"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("192.169.1.1"))

        // Non-RFC1918
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("8.8.8.8"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("1.1.1.1"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("127.0.0.1"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("169.254.1.1"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("256.0.0.1"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("10.0.0"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4("10.0.0.1.2"))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4(""))
        #expect(!IPAddressValidation.isRFC1918PrivateIPv4(nil))
    }

    @Test func buildsRouterAdminURL() {
        let url1 = IPAddressValidation.routerAdminURL(for: "192.168.1.1")
        #expect(url1?.absoluteString == "http://192.168.1.1")

        let url2 = IPAddressValidation.routerAdminURL(for: "10.0.0.1")
        #expect(url2?.absoluteString == "http://10.0.0.1")

        let url3 = IPAddressValidation.routerAdminURL(for: "8.8.8.8")
        #expect(url3 == nil)

        let url4 = IPAddressValidation.routerAdminURL(for: nil)
        #expect(url4 == nil)
    }
}
