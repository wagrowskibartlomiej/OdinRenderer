#+build linux

package engine

import "core:log"


import android "androidglue/ndkbindings"

when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] {

load_from_asset_pack_android :: proc() -> (asset: Asset, success: bool) {
	log.panic("Log from asset pack android not implemented")
}

}
