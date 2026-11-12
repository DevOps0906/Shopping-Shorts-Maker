import { notFound } from "next/navigation";
import { FeedbackDemo } from "@/components/feedback/feedback-demo";

/** 개발용 데모 화면. 프로덕션 빌드에서는 404. */
export default async function FeedbackDevPage({ searchParams }: { searchParams: Promise<{ preview?: string }> }) {
  if (process.env.NODE_ENV === "production") notFound();
  const { preview } = await searchParams;
  return <FeedbackDemo preview={preview === "1"} />;
}
