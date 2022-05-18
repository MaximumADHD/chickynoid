import { ChickynoidServer } from ".";
import PlayerRecord from "./PlayerRecord";

interface WeaponsServer {
	QueryBullet(
		playerRecord: PlayerRecord,
		server: typeof ChickynoidServer,
		origin: Vector3,
		dir: Vector3,
		serverTime: number,
		debugText: string,
	): [pos: Vector3, normal: Vector3, otherPlayerRecord: PlayerRecord];
}

interface WeaponsServerConstructor {
	/**
	 * Constructed internally. Do not use directly.
	 * @private
	 */
	new (): WeaponsServer;
}

declare const WeaponsServer: WeaponsServerConstructor;
export = WeaponsServer;