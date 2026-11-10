import TrackOrder from "@/components/track-order";

export default async function TrackPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  return <TrackOrder token={token} />;
}
