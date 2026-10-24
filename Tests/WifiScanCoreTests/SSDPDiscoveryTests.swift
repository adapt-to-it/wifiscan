import Foundation
import Testing
@testable import WifiScanCore

@Suite struct SSDPDiscoveryTests {

    @Test func parseResponseNormalizesKeysAndSkipsStatusLine() {
        let response = "HTTP/1.1 200 OK\r\n"
            + "CACHE-CONTROL: max-age=1800\r\n"
            + "location: http://192.168.1.1:5000/rootDesc.xml\r\n"
            + "SERVER: Linux/3.14 UPnP/1.0 IpBridge/1.0\r\n"
            + "ST: upnp:rootdevice\r\n"
            + "\r\n"
        let headers = SSDPDiscovery.parseResponse(response)
        #expect(headers["HTTP/1.1 200 OK"] == nil)
        #expect(headers["CACHE-CONTROL"] == "max-age=1800")
        #expect(headers["LOCATION"] == "http://192.168.1.1:5000/rootDesc.xml")
        #expect(headers["SERVER"] == "Linux/3.14 UPnP/1.0 IpBridge/1.0")
        #expect(headers["ST"] == "upnp:rootdevice")
        #expect(headers.count == 4)
    }

    @Test func parseDescriptionReadsDirectDeviceChildren() {
        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device>
            <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
            <friendlyName>  Soggiorno TV  </friendlyName>
            <manufacturer>Samsung</manufacturer>
            <modelName>UE55</modelName>
            <deviceList>
              <device><friendlyName>Embedded</friendlyName><modelName>Sub</modelName></device>
            </deviceList>
          </device>
        </root>
        """
        let result = SSDPDiscovery.parseDescription(Data(xml.utf8))
        #expect(result.friendlyName == "Soggiorno TV")
        #expect(result.manufacturer == "Samsung")
        #expect(result.modelName == "UE55")
    }

    @Test func parseDescriptionEmptyValueIsNil() {
        let xml = "<root><device><friendlyName>   </friendlyName><manufacturer>Acme</manufacturer></device></root>"
        let result = SSDPDiscovery.parseDescription(Data(xml.utf8))
        #expect(result.friendlyName == nil)
        #expect(result.manufacturer == "Acme")
        #expect(result.modelName == nil)
    }

    @Test func parseDescriptionBrokenXMLReturnsNil() {
        let xml = "<root><device><friendlyName>Oops</device><manufacturer>Acme"
        let result = SSDPDiscovery.parseDescription(Data(xml.utf8))
        #expect(result.friendlyName == nil)
        #expect(result.manufacturer == nil)
        #expect(result.modelName == nil)
    }

    @Test func isRandomizedChecksLocallyAdministeredBit() {
        #expect(MACAddress.isRandomized("da:a1:19:00:11:22") == true)
        #expect(MACAddress.isRandomized("a4:2b:b0:00:11:22") == false)
        #expect(MACAddress.isRandomized("x") == false)
    }
}
