import { Link, Row, Text } from '@react-email/components';
import * as React from 'react';
import ImmichLayout from 'src/emails/components/immich.layout';
import { TestEmailProps } from 'src/repositories/email.repository';

export const TestEmail = ({ baseUrl, displayName }: TestEmailProps) => (
  <ImmichLayout preview="This is a test email from Inhouse Photos.">
    <Text className="m-0">
      Hey <strong>{displayName}</strong>!
    </Text>

    <Text>This is a test email from your Inhouse Photos server!</Text>

    <Row>
      <Link href={baseUrl}>{baseUrl}</Link>
    </Row>
  </ImmichLayout>
);

TestEmail.PreviewProps = {
  baseUrl: 'https://fotos.miguelcoxcaballero.com',
  displayName: 'Alan Turing',
} as TestEmailProps;

export default TestEmail;
