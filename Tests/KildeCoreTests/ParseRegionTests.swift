import XCTest
@testable import KildeCore

final class ParseRegionTests: XCTestCase {

    func testValidForms() {
        XCTAssertEqual(parseRegion("0,0,1280,720"), CGRect(x: 0, y: 0, width: 1280, height: 720))
        XCTAssertEqual(parseRegion("100,50,640,360"), CGRect(x: 100, y: 50, width: 640, height: 360))
        // 空白は許容する (シェルのクォート越しに書きやすくするため)
        XCTAssertEqual(parseRegion(" 10 , 20 , 30 , 40 "), CGRect(x: 10, y: 20, width: 30, height: 40))
        // 小数も受ける (ポイント座標なので Retina では 0.5 単位がありうる)
        XCTAssertEqual(parseRegion("0,0,640.5,360.5"), CGRect(x: 0, y: 0, width: 640.5, height: 360.5))
        // 奇数サイズはここでは通し、偶数への切り捨ては収録時に行う
        XCTAssertEqual(parseRegion("0,0,641,361"), CGRect(x: 0, y: 0, width: 641, height: 361))
    }

    func testRejectsMalformed() {
        XCTAssertNil(parseRegion(nil))
        XCTAssertNil(parseRegion(""))
        XCTAssertNil(parseRegion("0,0,640"))          // 要素不足
        XCTAssertNil(parseRegion("0,0,640,360,10"))   // 要素過多
        XCTAssertNil(parseRegion("0,0,640x360"))      // 区切りが不正
        XCTAssertNil(parseRegion("a,b,c,d"))
        XCTAssertNil(parseRegion("0,0,,360"))         // 空の要素
        XCTAssertNil(parseRegion("0,0,1.2.3,360"))    // 数値として不正
    }

    func testRejectsNonPositiveSize() {
        XCTAssertNil(parseRegion("0,0,0,360"))
        XCTAssertNil(parseRegion("0,0,640,0"))
        // 負の値は数字として受け付けない (符号を許すと "1-2" のような入力も通ってしまう)
        XCTAssertNil(parseRegion("-10,0,640,360"))
        XCTAssertNil(parseRegion("0,0,-640,360"))
    }
}
