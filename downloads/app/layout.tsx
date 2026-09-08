import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = {title: 'Descargas · Inhouse Photos', description: 'Descarga Inhouse Photos para Android y administra tu servidor desde Windows.', icons: { icon: '/descargas/inhouse.svg' }};
export default function RootLayout({children}: Readonly<{children: React.ReactNode}>) {return <html lang="es"><body>{children}</body></html>;}
