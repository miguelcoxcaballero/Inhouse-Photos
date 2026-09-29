import { Column, Img, Link, Row, Text } from '@react-email/components';
import * as React from 'react';

export const ImmichFooter = ({ upstreamLicense = false }: { upstreamLicense?: boolean }) =>
  upstreamLicense ? (
    <>
      <Row className="h-18 w-full">
        <Column align="center" className="w-6/12 sm:w-full">
          <div>
            <Link href="https://play.google.com/store/apps/details?id=app.alextran.immich" className="object-contain">
              <Img
                alt="Get it on Google Play"
                className="max-w-full"
                src={`https://immich.app/img/google-play-badge.png`}
              />
            </Link>
          </div>
        </Column>
        <Column align="center" className="w-6/12 sm:w-full">
          <div className="h-full p-6">
            <Link href="https://apps.apple.com/sg/app/immich/id1613945652">
              <Img
                alt="Download on the App Store"
                className="max-w-full"
                src={`https://immich.app/img/ios-app-store-badge.png`}
              />
            </Link>
          </div>
        </Column>
      </Row>

      <Text className="text-center text-sm text-immich-footer">
        <Link href="https://immich.app">Immich</Link> project is available under GNU AGPL v3 license.
      </Text>
    </>
  ) : (
    <>
      <Text className="text-center text-sm text-immich-footer">
        <Link href="https://fotos.miguelcoxcaballero.com/descargas/">Download Inhouse Photos</Link>
      </Text>
      <Text className="text-center text-sm text-immich-footer">
        Inhouse Photos is open source.{' '}
        <Link href="https://github.com/miguelcoxcaballero/Inhouse-Photos">Source code</Link>
        {' · '}Based on <Link href="https://github.com/immich-app/immich">Immich</Link> (GNU AGPL v3).
      </Text>
    </>
  );
